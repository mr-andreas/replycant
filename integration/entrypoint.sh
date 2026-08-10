#!/bin/bash
set -euo pipefail

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
