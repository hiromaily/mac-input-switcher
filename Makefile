APP_NAME      := MacInputSwitcher
EXEC_NAME     := mac-input-switcher
BUNDLE_ID     := com.hiromaily.mac-input-switcher
SIGN_IDENTITY ?= mac-input-switcher-local

APP           := build/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
AGENT_PLIST   := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
LOG_FILE      := $(HOME)/Library/Logs/$(EXEC_NAME).log
USER_ID       := $(shell id -u)

.PHONY: test build sign install uninstall logs clean

test:
	swift test

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/$(EXEC_NAME) $(APP)/Contents/MacOS/$(EXEC_NAME)

sign: build
	codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)

install: sign
	-launchctl bootout gui/$(USER_ID)/$(BUNDLE_ID) 2>/dev/null
	mkdir -p $(INSTALL_DIR) $(dir $(AGENT_PLIST)) $(dir $(LOG_FILE))
	rm -rf $(INSTALLED_APP)
	cp -R $(APP) $(INSTALLED_APP)
	sed -e "s|__APP_EXEC__|$(INSTALLED_APP)/Contents/MacOS/$(EXEC_NAME)|" \
	    -e "s|__LOG__|$(LOG_FILE)|" \
	    LaunchAgent/$(BUNDLE_ID).plist > $(AGENT_PLIST)
	launchctl bootstrap gui/$(USER_ID) $(AGENT_PLIST)
	@echo "Installed. Grant Input Monitoring and Accessibility to $(APP_NAME) if prompted."

uninstall:
	-launchctl bootout gui/$(USER_ID)/$(BUNDLE_ID) 2>/dev/null
	rm -f $(AGENT_PLIST)
	rm -rf $(INSTALLED_APP)

logs:
	tail -f $(LOG_FILE)

clean:
	rm -rf .build build
