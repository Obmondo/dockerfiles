# Use the official Golang image to build the application
FROM golang:1.23 AS builder

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the go.mod files first to leverage Docker cache
COPY puppet-agent-exporter/exporter/go.mod ./

# Download all dependencies. Dependencies will be cached if the go.mod and go.sum files are not changed
RUN go mod download

# Copy the source code into the container
COPY puppet-agent-exporter/exporter/ ./

# Used for testings
# COPY metrics/ metrics/

# Build the Go app
RUN CGO_ENABLED=0 go build -o exporter .

# Start a new stage from scratch
FROM alpine:latest

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the Pre-built binary file from the previous stage
COPY --from=builder /app/exporter .

# Used for testing
# COPY --from=builder /app/metrics/ /var/lib/prometheus-dropzone/

# Expose port 8080 
EXPOSE 8080

# Command to run the executable
ENTRYPOINT ["./exporter"]
