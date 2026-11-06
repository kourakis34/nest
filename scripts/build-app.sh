#!/usr/bin/env bash
# Builds NotchAgents.app into ./build and optionally installs it to /Applications.
#   ./scripts/build-app.sh            # build only
#   ./scripts/build-app.sh --install  # build, copy to /Applications, launch
set -euo pipefail
cd "$(dirname "$0")/.."

# macOS ties Accessibility / Full Disk Access permissions to the app's code signature.
# A throwaway ("ad-hoc") signature changes on every build, so macOS would treat each
# rebuild as a new app and silently drop the permissions. Instead we create a local
# self-signed signing identity once, in your login keychain, and reuse it for every
# build so permissions stick. It never leaves this Mac.
IDENTITY="NotchAgents Local Signing"

ensure_identity() {
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    return 0
  fi
  echo "Creating local code-signing identity \"$IDENTITY\" (one time)..."
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$tmp/cert.cfg" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$IDENTITY" -out "$tmp/id.p12" -passout pass:notchagents >/dev/null 2>&1
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P notchagents -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"
  FIRST_SIGNING=1
}

FIRST_SIGNING=0

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchAgents"
[ -f "$BIN" ] || BIN="$(find .build -type f -name NotchAgents -path '*release*' | head -1)"

APP="build/NotchAgents.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchAgents"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/icons ]; then cp -R Resources/icons "$APP/Contents/Resources/icons"; fi

SIGNED_WITH="ad-hoc"
if ensure_identity && codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
  SIGNED_WITH="$IDENTITY"
else
  echo "warning: couldn't use the local signing identity; falling back to ad-hoc signing."
  echo "         Permissions may need to be re-granted after each rebuild."
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP (signed: $SIGNED_WITH)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NotchAgents 2>/dev/null || true
  rm -rf /Applications/NotchAgents.app
  cp -R "$APP" /Applications/
  open /Applications/NotchAgents.app
  echo "Installed and launched /Applications/NotchAgents.app"
fi

if [[ "$FIRST_SIGNING" == "1" ]]; then
  cat <<'MSG'

One-time step: the app now has a permanent signature, so macOS sees it as new.
In System Settings → Privacy & Security, under BOTH "Accessibility" and
"Full Disk Access": remove any old NotchAgents entry (select it, press −),
then add /Applications/NotchAgents.app again with + and switch it on.
Then quit and reopen Notch Agents. After this, rebuilds keep the permissions.
MSG
fi
