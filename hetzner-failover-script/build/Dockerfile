# syntax=docker/dockerfile:1

#--- Builder stage ---

FROM golang:1.23.0 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download -x

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-w -w" -v -o hetzner-failover-script ./cmd/

#--- Packager stage ---

FROM alpine:3.22.0

# Set the maintainer label
LABEL org.opencontainers.image.authors="ashish@obmondo.com, archisman@obmondo.com"

WORKDIR /app

COPY --from=builder /app/hetzner-failover-script .

CMD ["/app/hetzner-failover-script"]

