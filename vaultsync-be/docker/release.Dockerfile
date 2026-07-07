FROM scratch
WORKDIR /app
COPY vaultsync /app/vaultsync
ENTRYPOINT ["/app/vaultsync"]
