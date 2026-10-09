.PHONY: build run install uninstall clean

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
