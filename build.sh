#!/usr/bin/env bash
# Builds Mac Whisper.app and optionally a .dmg.
#
# Usage:
#   ./build.sh              # build the .app (default)
#   ./build.sh run          # build + launch (loads .env if present)
#   ./build.sh install      # build + copy to /Applications
#   ./build.sh dmg          # build + package a DMG
#   ./build.sh clean        # remove build artifacts
#   ./build.sh cert         # create a stable self-signed signing identity
#   ./build.sh debug        # build + attach lldb
#   ./build.sh logs         # build + launch + stream process logs
#   ./build.sh telemetry    # build + launch + stream subsystem telemetry
#   ./build.sh verify       # build + launch + confirm process is alive
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mac Whisper"
EXEC_NAME="MacWhisper"
BUNDLE_ID="com.solo.macwhisper"
CONFIG="release"
SWIFT_BUILD=".build/${CONFIG}"
APP_BUNDLE="build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"
INSTALL_DIR="/Applications"
SIGN_ID="MacWhisper Local Signing"
# Single source of truth for the version is package.json (managed by bun).
VERSION="$(grep -m1 '"version"' package.json | sed 's/[^0-9.]//g')"

# ── build: compile the Swift executable ────────────────────────────────
do_build() {
	echo "==> Compiling (${CONFIG})"
	swift build -c "$CONFIG"
}

# ── app: assemble and codesign the .app bundle ─────────────────────────
do_app() {
	do_build
	echo "==> Assembling ${APP_BUNDLE}"
	rm -rf "$APP_BUNDLE"
	mkdir -p "$MACOS_DIR" "$RES_DIR"
	cp "${SWIFT_BUILD}/${EXEC_NAME}" "${MACOS_DIR}/${EXEC_NAME}"

	# Inline Info.plist, then stamp the version from package.json.
	cat > "${CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Mac Whisper</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Whisper</string>
    <key>CFBundleIdentifier</key>
    <string>com.solo.macwhisper</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MacWhisper</string>
    <key>CFBundleIconFile</key>
    <string>MacWhisper</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mac Whisper needs microphone access to transcribe your speech.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Mac Whisper uses speech recognition to convert your speech to text.</string>
</dict>
</plist>
PLIST
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString ${VERSION}" \
		-c "Set :CFBundleVersion ${VERSION}" \
		"${CONTENTS}/Info.plist"

	cp public/assets/icon/MacWhisper.icns "${RES_DIR}/MacWhisper.icns"
	echo "APPL????" > "${CONTENTS}/PkgInfo"

	# Inline entitlements to a temp file (needed for mic/speech TCC).
	ENT_TMP="$(mktemp -t macwhisper_entitlements.XXXXXX)"
	trap 'rm -f "$ENT_TMP"' EXIT
	cat > "$ENT_TMP" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENT

	if security find-identity -p codesigning | grep -q "$SIGN_ID"; then
		echo "==> Codesigning with stable identity: ${SIGN_ID}"
		codesign --force --deep --sign "$SIGN_ID" \
			--entitlements "$ENT_TMP" --options runtime "$APP_BUNDLE"
	else
		echo "==> Codesigning ad-hoc (permissions reset on each rebuild)"
		echo "    Run './build.sh cert' once for stable, persistent permissions."
		codesign --force --deep --sign - \
			--entitlements "$ENT_TMP" --options runtime "$APP_BUNDLE" || \
		codesign --force --deep --sign - --entitlements "$ENT_TMP" "$APP_BUNDLE"
	fi
	rm -f "$ENT_TMP"
	trap - EXIT
	echo "==> Built ${APP_BUNDLE}"
}

# ── dmg: package a DMG with a custom Finder window ─────────────────────
do_dmg() {
	[ -d "$APP_BUNDLE" ] || do_app
	echo "==> Packaging DMG"
	DMG_FILE="build/MacWhisper.dmg"
	DMG_RW="build/MacWhisper-rw.dmg"
	DMG_STAGE="build/dmg-stage"
	BG_SRC="public/assets/dmg/dmg-background.png"

	if [ ! -f "$BG_SRC" ]; then
		echo "error: background not found at ${BG_SRC}" >&2
		exit 1
	fi

	# Background image is 660x440; window matches it exactly.
	WIN_W=660; WIN_H=440; ICON_SIZE=80
	APP_POS="180, 200"; APPS_POS="480, 200"

	echo "==> Staging DMG contents"
	rm -rf "$DMG_STAGE" "$DMG_FILE" "$DMG_RW"
	mkdir -p "$DMG_STAGE/.background"
	cp -R "$APP_BUNDLE" "$DMG_STAGE/"
	ln -s /Applications "$DMG_STAGE/Applications"
	cp "$BG_SRC" "$DMG_STAGE/.background/dmg-background.png"

	echo "==> Creating read-write DMG"
	hdiutil create \
		-volname "$APP_NAME" \
		-srcfolder "$DMG_STAGE" \
		-ov \
		-format UDRW \
		"$DMG_RW" >/dev/null
	rm -rf "$DMG_STAGE"

	echo "==> Mounting read-write DMG"
	hdiutil attach "$DMG_RW" -nobrowse -mountpoint /tmp/mw-dmg-mount 2>&1 | tail -1

	echo "==> Configuring Finder window background and icon layout"
	osascript <<APPLESCRIPT
tell application "Finder"
    set theDisk to POSIX file "/tmp/mw-dmg-mount" as alias
    set theWindow to make new Finder window to theDisk
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set bounds of theWindow to {0, 0, $WIN_W, $WIN_H}
    set icon size of icon view options of theWindow to $ICON_SIZE
    set arrangement of icon view options of theWindow to not arranged
    set background picture of icon view options of theWindow to file ".background:dmg-background.png" of theDisk
    set position of item "$APP_NAME.app" of theDisk to {$APP_POS}
    set position of item "Applications" of theDisk to {$APPS_POS}
    close theWindow
end tell
APPLESCRIPT

	# Give Finder a moment before eject.
	sleep 1

	echo "==> Ejecting (flushes .DS_Store into the DMG)"
	hdiutil detach /tmp/mw-dmg-mount >/dev/null

	echo "==> Converting to compressed read-only DMG"
	hdiutil convert "$DMG_RW" -format UDZO -ov -o "$DMG_FILE" >/dev/null
	rm -f "$DMG_RW"
	echo "==> Built ${DMG_FILE}"
}

# ── run: build then launch, loading .env if present ─────────────────────
do_run() {
	do_app
	echo "==> Launching ${APP_BUNDLE}"
	if [ -f .env ]; then
		set -a; . ./.env; set +a
		echo "==> Loaded .env (MACWHISPER_LLM_API_KEY: $([ -n "${MACWHISPER_LLM_API_KEY:-}" ] && echo set || echo not set))"
	else
		echo "==> No .env found (copy .env.example to .env to set the API key)"
	fi
	open "$APP_BUNDLE"
}

# ── install: copy into /Applications ────────────────────────────────────
do_install() {
	do_app
	echo "==> Installing to ${INSTALL_DIR}/${APP_BUNDLE}"
	rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
	cp -R "$APP_BUNDLE" "${INSTALL_DIR}/${APP_BUNDLE}"
	echo "==> Installed. Launch from /Applications or Spotlight."
}

# ── clean: remove build artifacts ───────────────────────────────────────
do_clean() {
	echo "==> Cleaning"
	rm -rf .build build
}

# ── cert: create a stable self-signed signing identity ──────────────────
do_cert() {
	CERT_CN="$SIGN_ID"
	LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

	if security find-identity -p codesigning | grep -q "$CERT_CN"; then
		echo "==> Signing identity '${CERT_CN}' already exists; nothing to do."
		return 0
	fi

	echo "==> Creating self-signed code-signing certificate '${CERT_CN}'"
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	PW="macwhisper"

	openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
		-days 3650 -nodes \
		-subj "/CN=${CERT_CN}" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" \
		-addext "basicConstraints=critical,CA:false"

	# Apple's `security` tool cannot read OpenSSL 3.x default PKCS#12 MACs, so export
	# with the legacy SHA1/3DES algorithms it understands.
	openssl pkcs12 -export -out "$TMP/cert.p12" \
		-inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
		-passout "pass:${PW}" -name "${CERT_CN}" \
		-legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

	# -A allows codesign to use the private key without per-build keychain prompts.
	security import "$TMP/cert.p12" -k "$LOGIN_KC" -P "$PW" -T /usr/bin/codesign -A

	echo "==> Imported '${CERT_CN}' into the login keychain."
	echo "    Rebuild with './build.sh'; permissions you grant will now persist."
}

# ── debug/logs/telemetry/verify: build + launch with diagnostics ────────
do_debug() {
	do_app
	pkill -x "$EXEC_NAME" >/dev/null 2>&1 || true
	lldb -- "${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}"
}

do_logs() {
	do_app
	pkill -x "$EXEC_NAME" >/dev/null 2>&1 || true
	open -n "$APP_BUNDLE"
	/usr/bin/log stream --info --style compact --predicate "process == \"${EXEC_NAME}\""
}

do_telemetry() {
	do_app
	pkill -x "$EXEC_NAME" >/dev/null 2>&1 || true
	open -n "$APP_BUNDLE"
	/usr/bin/log stream --info --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
}

do_verify() {
	do_app
	pkill -x "$EXEC_NAME" >/dev/null 2>&1 || true
	open -n "$APP_BUNDLE"
	sleep 1
	pgrep -x "$EXEC_NAME" >/dev/null
	echo "==> ${EXEC_NAME} is running"
}

# ── dispatch ────────────────────────────────────────────────────────────
case "${1:-app}" in
	app)        do_app ;;
	build)      do_build ;;
	run)        do_run ;;
	install)    do_install ;;
	dmg)        do_dmg ;;
	clean)      do_clean ;;
	cert)       do_cert ;;
	debug)      do_debug ;;
	logs)       do_logs ;;
	telemetry)  do_telemetry ;;
	verify)     do_verify ;;
	-h|--help|help)
		echo "usage: ./build.sh [app|build|run|install|dmg|clean|cert|debug|logs|telemetry|verify]"
		;;
	*)
		echo "error: unknown command '${1}'" >&2
		echo "usage: ./build.sh [app|build|run|install|dmg|clean|cert|debug|logs|telemetry|verify]" >&2
		exit 2
		;;
esac
