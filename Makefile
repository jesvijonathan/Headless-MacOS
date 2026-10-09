.PHONY: build run install uninstall clean save-config

build:
	scripts/build.sh

run: build
	open build/Headless.app

install: build
	sudo scripts/install.sh

uninstall:
	sudo scripts/uninstall.sh

clean:
	rm -rf build

# Snapshot this Mac's settings and fan mode into config/, restored by `make install`
# on a fresh machine (only when that machine has no settings yet).
save-config:
	mkdir -p config
	cp "$(HOME)/Library/Application Support/Headless/settings.plist" config/settings.plist
	@if [ -f "/Library/Application Support/Headless/fan.plist" ]; then cp "/Library/Application Support/Headless/fan.plist" config/fan.plist; fi
	@echo "Saved to config/ - commit it to carry your setup to a new install."
