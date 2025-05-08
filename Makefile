.PHONY: all build test run run-http clean bench docs

all: build

build:
	zig build

test:
	zig build test

run:
	./zig-out/bin/mcp_server

run-http:
	./zig-out/bin/mcp_server --transport http

bench:
	zig build bench

docs:
	zig build docs

clean:
	rm -rf zig-out/ zig-cache/
