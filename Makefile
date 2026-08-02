# vinboard — build & deploy
ZIG  ?= zig
DB   ?= $(HOME)/.local/state/vinboard/vinboard.db
PORT ?= 4670
# Archives pages through Safari (safaridriver --mcp). Set ARCHIVER=single-file
# to switch back to the Chromium-based archiver.
ARCHIVER ?= $(CURDIR)/scripts/safari-archive.js
# Ensure the spawned archiver (single-file) resolves; it lives on the mise shim path.
SHIMS = $(HOME)/.local/share/mise/shims

export NO_COLOR=1

.PHONY: build test run start-vinboard stop-vinboard install-deps

build:
	$(ZIG) build --summary none -Doptimize=ReleaseSafe

test:
	$(ZIG) build test --summary all

run: build
	./zig-out/bin/vinboard --db $(DB) --port $(PORT) --base-path /vinboard --archiver $(ARCHIVER)

# Run detached under dtach (same pattern as Textpod). PATH carries the mise
# shims so the archive worker can exec `single-file`.
start: build
	mkdir -p $(HOME)/vinboard
	dtach -n /tmp/vinboard.sock env PATH="$(SHIMS):$$PATH" \
	  ./zig-out/bin/vinboard --db $(DB) --port $(PORT) --base-path /vinboard --archiver $(ARCHIVER)

stop:
	-pkill -f 'zig-out/bin/vinboard'

# Archiver: single-file drives headless Chrome — Chrome/Chromium must be
# installed separately for archiving to work (the server runs fine without it;
# archive jobs just record status 'failed').
install-deps:
	npm install -g single-file-cli
