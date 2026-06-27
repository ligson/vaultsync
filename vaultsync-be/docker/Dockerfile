FROM golang:1.24 AS build
WORKDIR /src
COPY . .
RUN cd vaultsync-be && go build -o /out/vaultsync ./cmd/server

FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /out/vaultsync /app/vaultsync
ENTRYPOINT ["/app/vaultsync"]
