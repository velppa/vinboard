# vinboard — build & deploy
ZIG  ?= zig
DB   ?= $(HOME)/.local/state/vinboard/vinboard.db
PORT ?= 4670
# Archives pages through Safari (safaridriver --mcp).

export NO_COLOR=1

.PHONY: build test run start-vinboard stop-vinboard install-deps

build:
	NO_COLOR=1 $(ZIG) build --summary none -Doptimize=ReleaseSafe
	rm ~/.local/bin/vinboard
	ln -s $(CURDIR)/zig-out/bin/vinboard ~/.local/bin

test:
	$(ZIG) build test --summary all

run:
	vinboard --base-path /vinboard

# Run detached under dtach.
start:
	dtach -n /tmp/vinboard.sock \
	  vinboard --base-path /vinboard

stop:
	-pkill -f 'vinboard'

# Archiver: single-file drives headless Chrome — Chrome/Chromium must be
# installed separately for archiving to work (the server runs fine without it;
# archive jobs just record status 'failed').
install-deps:
	npm install -g single-file-cli
