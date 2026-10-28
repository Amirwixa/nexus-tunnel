BINARY_NAME=nexus
VERSION=3.5.0
BUILD_DIR=build

.PHONY: all build clean release test

all: build

build:
	@echo "Building NexusTunnel for current platform..."
	go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BINARY_NAME) cmd/nexus/main.go

release: clean
	@echo "Cross-compiling release binaries..."
	@mkdir -p $(BUILD_DIR)
	# Linux AMD64
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BUILD_DIR)/nexus_linux_amd64 cmd/nexus/main.go
	tar -czf $(BUILD_DIR)/nexus_linux_amd64.tar.gz -C $(BUILD_DIR) nexus_linux_amd64
	# Linux ARM64
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BUILD_DIR)/nexus_linux_arm64 cmd/nexus/main.go
	tar -czf $(BUILD_DIR)/nexus_linux_arm64.tar.gz -C $(BUILD_DIR) nexus_linux_arm64
	# macOS AMD64 & ARM64
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BUILD_DIR)/nexus_darwin_amd64 cmd/nexus/main.go
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BUILD_DIR)/nexus_darwin_arm64 cmd/nexus/main.go
	# Windows AMD64
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BUILD_DIR)/nexus_windows_amd64.exe cmd/nexus/main.go
	@echo "Release builds completed in $(BUILD_DIR)/"

clean:
	@rm -rf $(BUILD_DIR) $(BINARY_NAME)
