# Sui build tooling
.PHONY: all server build-server run-server test version-show version-check help clean

GO       := $(shell command -v go 2>/dev/null || echo /home/aiuser/go-sdk/go/bin/go)
GOFLAGS  :=
BIN      := server/bin/sui-server

# 版本号单一真源 = clients/flutter_app/pubspec.yaml 的 version 字段（见 ADR-018）。
# 服务端版本在构建期注入（version.String 是变量，-ldflags -X 只对变量生效）。
VERSION  := $(shell sed -n 's/^version:[[:space:]]*//p' clients/flutter_app/pubspec.yaml | head -1 | cut -d+ -f1)
LDFLAGS  := -X sui/note-server/internal/version.String=$(VERSION)

all: build-server

## server: build the Go server binary
build-server: version-check
	cd server && $(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o bin/sui-server ./cmd/sui-server

## run-server: build then run the server (addr overridable via SUI_ADDR)
run-server: build-server
	SUI_ADDR=$${SUI_ADDR:-127.0.0.1:8080} ./$(BIN)

## test: run all Go tests
test:
	cd server && $(GO) test ./...

## version-show: print the version source of truth and its derived targets
version-show:
	@bash scripts/version.sh show

## version-check: assert pubspec <-> version.go <-> CHANGELOG <-> git tag consistency
version-check:
	@bash scripts/version.sh check

## clean: remove build artifacts
clean:
	rm -rf server/bin

## help: print this message
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
