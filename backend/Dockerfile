# SOLVANTA API — multi-stage build with a non-root runtime user.
# Build:
#   docker build -t solvanta-api -f backend/Dockerfile backend
# Compose users just `docker compose up`.

FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/solvanta-api ./cmd/server

FROM alpine:3.24
RUN addgroup -S solvanta && adduser -S -G solvanta solvanta \
    && apk add --no-cache ca-certificates tzdata
COPY --from=build /out/solvanta-api /usr/local/bin/solvanta-api
USER solvanta
EXPOSE 8080
ENV ADDR=":8080"
ENTRYPOINT ["solvanta-api"]