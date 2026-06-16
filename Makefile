# vinboard — build & deploy
# Zig 0.16.0 via mise (system zig is the broken 0.15.2 on macOS 27).
ZIG  ?= $(HOME)/.local/share/mise/installs/zig/0.16.0/zig
DB   ?= $(HOME)/vinboard/vinboard.db
PORT ?= 4670
# Ensure the spawned archiver (single-file) resolves; it lives on the mise shim path.
SHIMS = $(HOME)/.local/share/mise/shims

.PHONY: build test run start-vinboard stop-vinboard install-deps

build:
	$(ZIG) build -Doptimize=ReleaseSafe

test:
	$(ZIG) build test --summary all

run: build
	./zig-out/bin/vinboard --db $(DB) --port $(PORT) --base-path /vinboard

# Run detached under dtach (same pattern as Textpod). PATH carries the mise
# shims so the archive worker can exec `single-file`.
start-vinboard: build
	mkdir -p $(HOME)/vinboard
	dtach -n /tmp/vinboard.sock env PATH="$(SHIMS):$$PATH" \
	  ./zig-out/bin/vinboard --db $(DB) --port $(PORT) --base-path /vinboard

stop-vinboard:
	-pkill -f 'zig-out/bin/vinboard'

# Archiver: single-file drives headless Chrome — Chrome/Chromium must be
# installed separately for archiving to work (the server runs fine without it;
# archive jobs just record status 'failed').
install-deps:
	npm install -g single-file-cli
