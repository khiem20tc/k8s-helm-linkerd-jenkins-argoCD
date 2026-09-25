# Build stage
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code (protobuf code is generated and committed; run `make proto` to regenerate)
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o main ./src

# Final stage
FROM alpine:3.20

# Install ca-certificates for HTTPS requests
RUN apk --no-cache add ca-certificates

# Create non-root user
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /app

# Copy the binary and default config from builder stage
COPY --from=builder --chown=appuser:appgroup /app/main .
COPY --from=builder --chown=appuser:appgroup /app/configs ./configs

# Switch to non-root user
USER 1001:1001

# Expose ports
EXPOSE 8080 50051

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Run the application
CMD ["./main"]
