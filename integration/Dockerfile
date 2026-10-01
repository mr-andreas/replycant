FROM ghcr.io/juanfont/headscale:0.29.3 AS headscale

FROM golang:1.26.6-trixie

RUN apt-get update && apt-get install -y --no-install-recommends git git-lfs openssl ca-certificates curl dnsmasq && rm -rf /var/lib/apt/lists/*

COPY --from=headscale /ko-app/headscale /usr/local/bin/headscale

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .

RUN go build -o /usr/local/bin/gitd ./server/bin/gitd
RUN go build -o /usr/local/bin/hsproxy ./server/bin/hsproxy
RUN go build -o /usr/local/bin/lfs-prereceive ./server/bin/lfs-prereceive
RUN go build -o /usr/local/bin/git-replycant ./git-replycant
RUN ln -s git-replycant /usr/local/bin/git-remote-replycant
RUN go build -o /usr/local/bin/discovery ./integration/discovery
RUN go build -o /usr/local/bin/seeder ./integration/seeder
RUN go build -o /usr/local/bin/provisioner ./integration/provisioner
RUN go build -o /usr/local/bin/ctl ./integration/ctl

COPY integration/entrypoint.sh /entrypoint.sh
COPY integration/reset-repo.sh /usr/local/bin/reset-repo.sh
RUN chmod +x /entrypoint.sh
RUN chmod +x /usr/local/bin/reset-repo.sh

ENTRYPOINT ["/entrypoint.sh"]
