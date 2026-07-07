IMAGE ?= ligson/vaultsync-be
TAG ?= $(shell git rev-parse --short HEAD)
RELEASE_BINARY := bin/vaultsync-linux-amd64
RELEASE_CONTEXT := bin/release-context

.PHONY: test run build release-binary release-image release-push clean-release

test:
	go test ./...

run:
	go run ./cmd/server -config config.yaml

build:
	mkdir -p bin
	go build -o bin/vaultsync ./cmd/server

release-binary:
	mkdir -p bin
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o $(RELEASE_BINARY) ./cmd/server

release-image: release-binary
	rm -rf $(RELEASE_CONTEXT)
	mkdir -p $(RELEASE_CONTEXT)
	cp $(RELEASE_BINARY) $(RELEASE_CONTEXT)/vaultsync
	cp docker/release.Dockerfile $(RELEASE_CONTEXT)/Dockerfile
	docker build --platform linux/amd64 -t $(IMAGE):$(TAG) -t $(IMAGE):latest $(RELEASE_CONTEXT)

release-push: release-image
	docker push $(IMAGE):$(TAG)
	docker push $(IMAGE):latest

clean-release:
	rm -rf $(RELEASE_BINARY) $(RELEASE_CONTEXT)
