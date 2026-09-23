# Sui build tooling
.PHONY: all server build-server run-server test help clean

GO       := $(shell command -v go 2>/dev/null || echo /home/aiuser/go-sdk/go/bin/go)
GOFLAGS  :=
BIN      := server/bin/sui-server

all: build-server

## server: build the Go server binary
build-server:
	cd server && $(GO) build $(GOFLAGS) -o bin/sui-server ./cmd/sui-server

## run-server: build then run the server (addr overridable via SUI_ADDR)
run-server: build-server
	SUI_ADDR=$${SUI_ADDR:-:8080} ./$(BIN)

## test: run all Go tests
test:
	cd server && $(GO) test ./...

## clean: remove build artifacts
clean:
	rm -rf server/bin

## help: print this message
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'