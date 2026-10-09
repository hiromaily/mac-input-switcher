APP_NAME      := MacInputSwitcher
EXEC_NAME     := mac-input-switcher
BUNDLE_ID     := com.hiromaily.mac-input-switcher
VERSION       := 0.0.0-dev

APP           := build/$(APP_NAME).app
LOG_FILE      := $(HOME)/Library/Logs/$(EXEC_NAME).log

.PHONY: test lint fmt build install uninstall logs clean

test:
	swift test
	scripts/test-install.sh

lint:
	swift format lint --strict --recursive Package.swift Sources Tests
	shellcheck install.sh scripts/test-install.sh

fmt:
	swift format format --in-place --recursive Package.swift Sources Tests

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	sed -e "s|__BUNDLE_ID__|$(BUNDLE_ID)|" \
	    -e "s|__VERSION__|$(VERSION)|" \
	    Resources/Info.plist > $(APP)/Contents/Info.plist
	cp .build/release/$(EXEC_NAME) $(APP)/Contents/MacOS/$(EXEC_NAME)

install: build
	./install.sh --app $(APP)

uninstall:
	./install.sh --uninstall

logs:
	tail -f $(LOG_FILE)

clean:
	rm -rf .build build
