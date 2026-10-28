BINARY_NAME=nexus-tunnel
MAIN_PATH=./cmd/nexus/main.go
LDFLAGS=-s -w

.PHONY: all build build-amd64 build-arm64 clean install

all: build

build:
	CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="$(LDFLAGS)" -o $(BINARY_NAME) $(MAIN_PATH)

build-amd64:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="$(LDFLAGS)" -o $(BINARY_NAME)-linux-amd64 $(MAIN_PATH)

build-arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="$(LDFLAGS)" -o $(BINARY_NAME)-linux-arm64 $(MAIN_PATH)

install:
	bash ./install.sh

clean:
	rm -f $(BINARY_NAME) $(BINARY_NAME)-linux-*
