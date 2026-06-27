.PHONY: test run build

test:
	go test ./...

run:
	go run ./cmd/server

build:
	mkdir -p bin
	go build -o bin/vaultsync ./cmd/server
