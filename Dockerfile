# Build for alpine
FROM golang:1.25.5-alpine3.23 AS alpine-builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . .
RUN go install ./...

# Build for debian
FROM golang:1.25.5-trixie AS debian-builder
WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . .
RUN go install ./...

# Run gitd on debian, as the git binary bundled with alpine does not contain git-http-backend.
FROM debian:trixie AS gitd
RUN apt-get update && apt-get install -y git
COPY --from=debian-builder /go/bin/gitd /usr/local/bin/gitd
COPY --from=debian-builder /go/bin/lfs-prereceive /usr/local/bin/lfs-prereceive
ENTRYPOINT ["/usr/local/bin/gitd"]
EXPOSE 8443
EXPOSE 8080

# Run transcoded on a plain Debian base because the active transcoding path
# is software-only and does not require CUDA runtime dependencies.
FROM debian:trixie AS transcoded
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=debian-builder /go/bin/transcoded /usr/local/bin/transcoded
ENTRYPOINT ["/usr/local/bin/transcoded"]
EXPOSE 8082

# Run decryptd as a lightweight decrypting proxy for encrypted LFS objects.
FROM alpine:3.23 AS decryptd
RUN apk add --no-cache ca-certificates
COPY --from=alpine-builder /go/bin/decryptd /usr/local/bin/decryptd
ENTRYPOINT ["/usr/local/bin/decryptd"]
EXPOSE 8084
