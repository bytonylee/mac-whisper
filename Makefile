APP_NAME    = Mac Whisper
EXEC_NAME   = MacWhisper
BUNDLE_ID   = com.solo.macwhisper
CONFIG      = release
SWIFT_BUILD = .build/$(CONFIG)
APP_BUNDLE  = build/$(APP_NAME).app
DMG_FILE    = build/$(EXEC_NAME).dmg
DMG_STAGE   = build/dmg-stage
CONTENTS    = $(APP_BUNDLE)/Contents
MACOS_DIR   = $(CONTENTS)/MacOS
RES_DIR     = $(CONTENTS)/Resources
INSTALL_DIR = /Applications
SIGN_ID     = MacWhisper Local Signing
# Single source of truth for the version is package.json (managed by bun).
VERSION     := $(shell grep -m1 '"version"' package.json | sed 's/[^0-9.]//g')

.PHONY: all build app dmg run install clean cert

all: app

## Compile the Swift executable
build:
	swift build -c $(CONFIG)

## Create a stable self-signed signing identity (one-time) so granted
## permissions (Input Monitoring, Accessibility) persist across rebuilds.
cert:
	@bash scripts/setup-signing-cert.sh

## Assemble and codesign the .app bundle
app: build
	@echo "==> Assembling $(APP_BUNDLE)"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp "$(SWIFT_BUILD)/$(EXEC_NAME)" "$(MACOS_DIR)/$(EXEC_NAME)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" "$(CONTENTS)/Info.plist"
	@cp public/assets/icon/MacWhisper.icns "$(RES_DIR)/MacWhisper.icns"
	@echo "APPL????" > "$(CONTENTS)/PkgInfo"
	@if security find-identity -p codesigning | grep -q "$(SIGN_ID)"; then \
		echo "==> Codesigning with stable identity: $(SIGN_ID)"; \
		codesign --force --deep --sign "$(SIGN_ID)" \
			--entitlements MacWhisper.entitlements --options runtime "$(APP_BUNDLE)"; \
	else \
		echo "==> Codesigning ad-hoc (permissions reset on each rebuild)"; \
		echo "    Run 'make cert' once for stable, persistent permissions."; \
		codesign --force --deep --sign - \
			--entitlements MacWhisper.entitlements --options runtime "$(APP_BUNDLE)" || \
		codesign --force --deep --sign - --entitlements MacWhisper.entitlements "$(APP_BUNDLE)"; \
	fi
	@echo "==> Built $(APP_BUNDLE)"

## Build then launch the app. Sources a gitignored repo-local .env (if present)
## so MACWHISPER_LLM_API_KEY is inherited by the launched app.
run: app
	@echo "==> Launching $(APP_BUNDLE)"
	@if [ -f .env ]; then \
		set -a; . ./.env; set +a; \
		echo "==> Loaded .env (MACWHISPER_LLM_API_KEY: $$([ -n "$$MACWHISPER_LLM_API_KEY" ] && echo set || echo not set))"; \
	else \
		echo "==> No .env found (copy .env.example to .env to set the API key)"; \
	fi
	@open "$(APP_BUNDLE)"

## Install into /Applications
install: app
	@echo "==> Installing to $(INSTALL_DIR)/$(APP_BUNDLE)"
	@rm -rf "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@echo "==> Installed. Launch from /Applications or Spotlight."

## Remove build artifacts
clean:
	@echo "==> Cleaning"
	@rm -rf .build build

## Create a DMG release artifact
dmg: app
	@echo "==> Packaging $(DMG_FILE)"
	@rm -rf "$(DMG_STAGE)" "$(DMG_FILE)"
	@mkdir -p "$(DMG_STAGE)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGE)/"
	@ln -s "$(INSTALL_DIR)" "$(DMG_STAGE)/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGE)" -ov -format UDZO "$(DMG_FILE)" >/dev/null
	@rm -rf "$(DMG_STAGE)"
	@echo "==> Built $(DMG_FILE)"
