.PHONY: test run build

test:
	go test ./...

run:
	go run ./cmd/server

build:
	go build -o bin/vaultsync ./cmd/server
