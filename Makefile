SHELL := /bin/bash

.PHONY: help format lint test build imsg clean build-dylib docs-site

help:
	@printf "%s\n" \
		"make format     - swift format in-place" \
		"make lint       - swift format lint + swiftlint" \
		"make test       - sync version, patch deps, run swift test" \
		"make build      - universal release build into bin/" \
		"make build-dylib - build injectable dylib for Messages.app" \
		"make imsg       - clean rebuild + run debug binary (ARGS=...)" \
		"make docs-site  - build the imsg.sh docs site into dist/docs-site" \
		"make clean      - swift package clean"

format:
	swift format --in-place --recursive Sources Tests TestsLinux

lint:
	swift format lint --recursive Sources Tests TestsLinux
	swiftlint

test:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift test

build:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	scripts/build-universal.sh

# Build injectable dylib for Messages.app (DYLD_INSERT_LIBRARIES).
# Uses arm64e architecture to match Messages.app on Apple Silicon.
# Requires SIP disabled on the target machine to inject into system apps.
build-dylib:
	@echo "Building imsg-bridge-helper.dylib (injectable)..."
	@mkdir -p .build/release
	@clang -dynamiclib -arch arm64e -fobjc-arc \
		-Wno-arc-performSelector-leaks \
		-install_name @rpath/imsg-bridge-helper.dylib \
		-framework Foundation \
		-framework AppKit \
		-framework ImageIO \
		-framework LinkPresentation \
		-o .build/release/imsg-bridge-helper.dylib \
		Sources/IMsgHelper/IMsgInjected.m
	@echo "Built .build/release/imsg-bridge-helper.dylib"

imsg:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift package clean
	swift build -c debug --product imsg
	./.build/debug/imsg $(ARGS)

docs-site:
	node scripts/build-docs-site.mjs

clean:
	swift package clean
	@rm -f .build/release/imsg-bridge-helper.dylib
	@rm -rf dist/docs-site
