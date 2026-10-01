#!/bin/bash
set -euo pipefail

# start_tailnet brings up the control plane and the tsnet gitd the CLI clones
# against. Ports stay off the ones the direct gitd already binds.
start_tailnet() {
  local headscale_port=18084
  local hsproxy_port=18085
  local ca_port=18081
  local discovery_port=18082

  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out /tmp/pki/tailnet.key
  openssl req -new -key /tmp/pki/tailnet.key -out /tmp/pki/tailnet.csr \
    -subj "/CN=gitd.replycant.internal" \
    -addext "subjectAltName=DNS:localhost,DNS:gitd.replycant.internal,IP:127.0.0.1"
  openssl x509 -req -in /tmp/pki/tailnet.csr -CA /tmp/pki/ca.crt -CAkey /tmp/pki/ca.key \
    -out /tmp/pki/tailnet.crt -days 2 -CAcreateserial -copy_extensions copyall

  # *.discovery.test has to resolve inside this container. dnsmasq answers
  # those names and forwards everything else to the resolver Docker already
  # installed. That is not always 127.0.0.11: Docker Desktop uses a gateway
  # address, and forwarding to the wrong one makes headscale's DERP fetch fail.
  # local= keeps AAAA queries for the fake discovery host from being forwarded
  # and hanging.
  local upstream
  upstream="$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)"
  if [[ -z "$upstream" ]]; then
    echo "could not read the container DNS resolver" >&2
    exit 1
  fi
  cat > /tmp/dnsmasq.conf << EOF
listen-address=127.0.0.1
bind-interfaces
port=53
no-resolv
server=${upstream}
local=/discovery.test/
address=/discovery.test/127.0.0.1
EOF
  dnsmasq -C /tmp/dnsmasq.conf
  printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf

  discovery --addr="127.0.0.1:${discovery_port}" >/tmp/discovery.log 2>&1 &

  mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /tmp/tailnet
  cat > /etc/headscale/config.yaml << EOF
server_url: https://localhost:${hsproxy_port}
listen_addr: 127.0.0.1:${headscale_port}
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
trusted_proxies: []
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: true
  update_frequency: 24h
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
tls_cert_path: ""
tls_key_path: ""
log:
  level: info
  format: text
policy:
  mode: file
  path: /etc/headscale/policy.json
dns:
  magic_dns: true
  base_domain: replycant.internal
  override_local_dns: false
  nameservers:
    global: []
  search_domains: []
EOF
  cat > /etc/headscale/policy.json << 'EOF'
{
  "tagOwners": {
    "tag:server": ["replycant@"],
    "tag:device": ["replycant@"]
  },
  "acls": [
    {
      "action": "accept",
      "proto": "tcp",
      "src": ["tag:device"],
      "dst": ["tag:server:8443", "tag:server:8444"]
    }
  ]
}
EOF

  headscale serve >/tmp/headscale.log 2>&1 &
  local headscale_pid=$!

  local ready=0
  for _ in $(seq 1 60); do
    if ! kill -0 "$headscale_pid" 2>/dev/null; then
      echo "headscale exited" >&2
      cat /tmp/headscale.log >&2 || true
      exit 1
    fi
    if timeout 3 headscale users list >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "headscale did not become ready" >&2
    cat /tmp/headscale.log >&2 || true
    exit 1
  fi

  json_number() {
    grep -o "\"$1\": *[0-9]*" | head -n1 | grep -o '[0-9]*$' || true
  }
  if [[ -z "$(headscale users list --name replycant --output json | json_number id)" ]]; then
    headscale users create replycant
  fi
  local user_id
  user_id="$(headscale users list --name replycant --output json | json_number id)"
  if [[ -z "$user_id" ]]; then
    echo "could not determine the replycant user id" >&2
    exit 1
  fi
  headscale preauthkeys create --user "$user_id" --expiration 24h --tags tag:server --output json \
    | grep -o '"key": *"[^"]*"' \
    | sed -e 's/.*: *"//' -e 's/"$//' \
    > /tmp/tailnet/gitd.authkey
  chmod 600 /tmp/tailnet/gitd.authkey
  if [[ ! -s /tmp/tailnet/gitd.authkey ]]; then
    echo "failed to mint a gitd pre-auth key" >&2
    exit 1
  fi
  headscale apikeys create --expiration 87600h | tr -d '\r\n' > /tmp/tailnet/headscale.apikey
  chmod 600 /tmp/tailnet/headscale.apikey
  if [[ ! -s /tmp/tailnet/headscale.apikey ]]; then
    echo "failed to mint a headscale API key" >&2
    exit 1
  fi

  # :port rather than 127.0.0.1. Clients dial "localhost", which resolves to
  # ::1 first, and a v4-only listener refuses that connection.
  hsproxy \
    --repo=/tmp/repo.git \
    --addr=":${hsproxy_port}" \
    --upstream="127.0.0.1:${headscale_port}" \
    --cert=/tmp/pki/tailnet.crt \
    --key=/tmp/pki/tailnet.key \
    --cache-ttl=1s \
    --health-addr=127.0.0.1:18086 >/tmp/hsproxy.log 2>&1 &
  local hsproxy_pid=$!
  sleep 0.5
  if ! kill -0 "$hsproxy_pid" 2>/dev/null; then
    echo "hsproxy exited" >&2
    cat /tmp/hsproxy.log >&2 || true
    exit 1
  fi

  # localhost is the manual-exposure hostname, so the CA-label check does
  # not try to match a fingerprint. gitd.replycant.internal is on the same
  # certificate for the in-tailnet control path.
  gitd \
    --repo=/tmp/repo.git \
    --addr=:8443 \
    --ca-addr="127.0.0.1:${ca_port}" \
    --cert=/tmp/pki/tailnet.crt \
    --key=/tmp/pki/tailnet.key \
    --ca=/tmp/pki/ca.crt \
    --hostname=localhost \
    --lfs-dir=/tmp/lfs \
    --lfs-internal-addr= \
    --decryptd-url=http://localhost:18445 \
    --transcoded-url=http://localhost:18446 \
    --cache-ttl=1s \
    --tsnet-dir=/tmp/tsnet-gitd \
    --tsnet-control-url="http://127.0.0.1:${headscale_port}" \
    --tsnet-hostname=gitd \
    --tsnet-auth-key-file=/tmp/tailnet/gitd.authkey \
    --tailnet-domain=replycant.internal \
    --tailnet-control-addr=:8444 \
    --tailnet-control-upstream="127.0.0.1:${hsproxy_port}" \
    --headscale-api-url="http://127.0.0.1:${headscale_port}" \
    --headscale-api-key-file=/tmp/tailnet/headscale.apikey \
    --headscale-client-url="https://localhost:${hsproxy_port}" \
    --discovery-url="http://discovery.test:${discovery_port}" >/tmp/gitd-tailnet.log 2>&1 &
  local tailnet_pid=$!

  for _ in $(seq 1 180); do
    if grep -q "Joined tailnet" /tmp/gitd-tailnet.log 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$tailnet_pid" 2>/dev/null; then
      echo "tailnet gitd exited before joining" >&2
      cat /tmp/gitd-tailnet.log >&2 || true
      cat /tmp/headscale.log >&2 || true
      exit 1
    fi
    sleep 1
  done
  echo "tailnet gitd did not join" >&2
  cat /tmp/gitd-tailnet.log >&2 || true
  cat /tmp/headscale.log >&2 || true
  exit 1
}

mkdir -p /tmp/pki /tmp/identity /tmp/lfs

# Generate CA and server certificates with SANs for localhost and 127.0.0.1.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out /tmp/pki/ca.key
openssl req -new -x509 -key /tmp/pki/ca.key -out /tmp/pki/ca.crt -days 2 \
  -subj "/CN=replycant-integration-ca" -addext "basicConstraints=critical,CA:TRUE"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out /tmp/pki/server.key
openssl req -new -key /tmp/pki/server.key -out /tmp/pki/server.csr \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
openssl x509 -req -in /tmp/pki/server.csr -CA /tmp/pki/ca.crt -CAkey /tmp/pki/ca.key \
  -out /tmp/pki/server.crt -days 2 -CAcreateserial -copy_extensions copyall

# Create and seed bare repository with authorized pubkey and encryption metadata.
git init --initial-branch=main --bare /tmp/repo.git
git -C /tmp/repo.git config http.receivepack true
seeder --bare-repo=/tmp/repo.git --output-dir=/tmp/identity

# Install git-lfs hooks from template for subsequent test repositories.
git lfs install

# The iOS and desktop suites keep the direct gitd above. The CLI suite opts
# into a real tailnet: headscale, hsproxy, a second gitd on tsnet, and a fake
# discovery host. Peers share this network namespace and connect directly;
# joining still fetches Tailscale's public DERP map.
if [[ "${REPLYCANT_INTEGRATION_TAILNET:-}" == "1" ]]; then
  start_tailnet
fi

# Start gitd server. The media upstreams are required flags but unused here;
# these integration tests only exercise Git and LFS, so nothing listens on them.
gitd \
  --repo=/tmp/repo.git \
  --addr=:18443 \
  --cert=/tmp/pki/server.crt \
  --key=/tmp/pki/server.key \
  --ca=/tmp/pki/ca.crt \
  --hostname=localhost \
  --lfs-dir=/tmp/lfs \
  --lfs-internal-addr= \
  --decryptd-url=http://localhost:18445 \
  --transcoded-url=http://localhost:18446 \
  --cache-ttl=1s >/tmp/gitd.log 2>&1 &

# Readiness signal is a successful local ls-remote call through mTLS.
for _ in $(seq 1 120); do
  if git \
    -c http.sslCAInfo=/tmp/pki/ca.crt \
    -c http.sslCert=/tmp/identity/client-cert.pem \
    -c http.sslKey=/tmp/identity/client-key.pem \
    ls-remote --heads https://localhost:18443/ >/tmp/ready-check.log 2>&1; then
    touch /tmp/ready
    exec sleep infinity
  fi
  sleep 1
done

echo "container startup failed" >&2
cat /tmp/gitd.log >&2 || true
exit 1
