# syntax=docker/dockerfile:1

#--- Builder stage ---

FROM golang:1.26 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download -x

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -v -o egress-node-labeller ./cmd/

#--- Packager stage ---

FROM alpine:3.22.0

# Set the maintainer label
LABEL org.opencontainers.image.authors="archisman@obmondo.com"

WORKDIR /app

COPY --from=builder /app/egress-node-labeller .

ENTRYPOINT ["/app/egress-node-labeller"]
