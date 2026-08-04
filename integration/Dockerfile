FROM golang:1.25.5-trixie

RUN apt-get update && apt-get install -y --no-install-recommends git git-lfs openssl ca-certificates curl && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .

RUN go build -o /usr/local/bin/gitd ./server/bin/gitd
RUN go build -o /usr/local/bin/lfs-prereceive ./server/bin/lfs-prereceive
RUN go build -o /usr/local/bin/git-replycant ./git-replycant
RUN go build -o /usr/local/bin/seeder ./integration/seeder
RUN go build -o /usr/local/bin/provisioner ./integration/provisioner
RUN go install github.com/git-lfs/lfs-test-server@latest

COPY integration/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
