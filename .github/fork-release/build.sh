#!/usr/bin/env bash
set -euo pipefail
platform="${1:?Specify macOS or iOS}"
: "${APP_VERSION:?}" "${APP_BUILD_NUMBER:?}" "${SOURCE_SHA:?}"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$(git rev-parse HEAD)" == "$SOURCE_SHA" ]]
test -f Shared/PeerToPeerWiFi.swift
git grep -q 'includePeerToPeer' -- Shared/StreamReceiver.swift
mkdir -p dist
short_sha="${SOURCE_SHA:0:7}"
suffix="${APP_VERSION}-${short_sha}"
derived="$PWD/DerivedData-${platform}"
{
  echo "Repository: ${GITHUB_REPOSITORY}"
  echo "Source commit: ${SOURCE_SHA}"
  echo "App version: ${APP_VERSION} (${APP_BUILD_NUMBER})"
  echo "Platform: ${platform}"
  echo "Workflow: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  echo "Build time (UTC): $(date -u +%FT%TZ)"
  sw_vers
  xcodebuild -version
  xcodegen --version
} > "dist/BUILD-INFO-${platform}.txt"

# The fork has its own feed, EdDSA key, bundle IDs and persistent signing identity.
xcodegen generate
common=(-project OpenSidecar.xcodeproj -derivedDataPath "$derived")
common+=(MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$APP_BUILD_NUMBER")
common+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
run_xcode() {
  local name="$1"; shift
  local log="${RUNNER_TEMP}/openairdisplay-${platform}-${name}.log"
  echo "Running xcodebuild: ${name}"
  if ! xcodebuild "$@" "${common[@]}" > "$log" 2>&1; then
    tail -120 "$log"
    return 1
  fi
  tail -5 "$log"
}

# The fork must not keep calling upstream's website, Sparkle feed or the App
# Store page. Check the linked executable, not just the sources.
upstream_strings='https://opendisplay.app
itms-apps://
peetzweg.github.io
apps.apple.com'
check_no_upstream_endpoints() {
  local binary="$1" needle
  # No pipeline here: a subshell could not abort the build.
  while IFS= read -r needle; do
    [[ -n "$needle" ]] || continue
    if grep -a -F -q -e "$needle" "$binary"; then
      echo "::error::Upstream endpoint still in $binary: $needle" >&2
      return 1
    fi
  done <<< "$upstream_strings"
  echo "No upstream endpoints in $binary"
}

case "$platform" in
  macOS)
    run_xcode tests test -scheme OpenSidecarMac -destination 'platform=macOS'
    for target in OpenSidecarMac OpenSidecarMacReceiver; do
      run_xcode "$target" build -scheme "$target" -configuration Release \
        -destination 'generic/platform=macOS' -sdk macosx \
        'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=NO
      product='OpenAirDisplay'; asset='OpenAirDisplay'
      if [[ "$target" == OpenSidecarMacReceiver ]]; then
        product='OpenAirDisplay Receiver'; asset='OpenAirDisplayReceiver'
      fi
      app="$derived/Build/Products/Release/${product}.app"
      python3 - "$app" >> dist/BUILD-INFO-macOS.txt <<'PY'
import os, plistlib, sys
from pathlib import Path
path = Path(sys.argv[1]) / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
assert info['CFBundleShortVersionString'] == os.environ['APP_VERSION']
assert info['CFBundleVersion'] == os.environ['APP_BUILD_NUMBER']
assert '_opensidecar._tcp' in info['NSBonjourServices']
import json
config=json.load(open('.github/fork-release/config.json'))
role='receiver' if 'Receiver' in sys.argv[1] else 'mac'
assert info['CFBundleIdentifier']==config['bundleIDs'][role], info['CFBundleIdentifier']
feed='openairdisplay-appcast-receiver.xml' if role=='receiver' else 'openairdisplay-appcast.xml'
assert info['SUFeedURL']=='https://raw.githubusercontent.com/nmt3325/openairdisplay/main/public/'+feed
assert info['SUPublicEDKey']==config['sparklePublicKey']
assert info['SUEnableAutomaticChecks'] is True
print(sys.argv[1], {k:info.get(k) for k in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion')})
PY
      executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
      lipo "$app/Contents/MacOS/$executable" -verify_arch arm64 x86_64
      check_no_upstream_endpoints "$app/Contents/MacOS/$executable" >> dist/BUILD-INFO-macOS.txt
      bash .github/fork-release/sign-mac-app.sh "$app" "$asset"
      echo "${product}: persistent certificate signature and stable DR verified; arm64 + x86_64 verified." >> dist/BUILD-INFO-macOS.txt
      archive="dist/${asset}-macOS-signed-universal-${suffix}.zip"
      ditto -c -k --keepParent "$app" "$archive"
      signature=$("$SPARKLE_SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" -p "$archive")
      "$SPARKLE_SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$archive" "$signature"
      python3 - "$archive" "$signature" "$app" <<'SIGNATURE'
import base64, json, os, plistlib, sys
from pathlib import Path
archive=Path(sys.argv[1]); signature=sys.argv[2]
assert len(base64.b64decode(signature,validate=True))==64
info=plistlib.loads((Path(sys.argv[3])/'Contents/Info.plist').read_bytes())
p=Path('dist/MAC-UPDATES.json'); rows=json.loads(p.read_text()) if p.exists() else []
rows.append({'asset':archive.name,'signature':signature,'length':archive.stat().st_size,
 'bundleID':info['CFBundleIdentifier'],'version':os.environ['APP_VERSION'],
 'buildNumber':os.environ['APP_BUILD_NUMBER'],'minimumSystemVersion':info['LSMinimumSystemVersion'],
 'sourceSHA':os.environ['SOURCE_SHA']})
p.write_text(json.dumps(rows,indent=2)+'\n')
SIGNATURE
    done
    cp .github/fork-release/OpenAirDisplay-code-signing.pem dist/
    ;;
  iOS)
    run_xcode OpenSidecariOS build -scheme OpenSidecariOS -configuration Release \
      -destination 'generic/platform=iOS' -sdk iphoneos ONLY_ACTIVE_ARCH=NO
    app="$derived/Build/Products/Release-iphoneos/OpenAirDisplay.app"
    python3 - "$app" >> dist/BUILD-INFO-iOS.txt <<'PY'
import json, os, plistlib, sys
from pathlib import Path
path = Path(sys.argv[1]) / 'Info.plist'
info = plistlib.loads(path.read_bytes())
config = json.load(open('.github/fork-release/config.json'))
assert info['CFBundleIdentifier'] == config['bundleIDs']['ios'], info['CFBundleIdentifier']
assert info['CFBundleShortVersionString'] == os.environ['APP_VERSION']
assert info['CFBundleVersion'] == os.environ['APP_BUILD_NUMBER']
assert 'iPhoneOS' in info['CFBundleSupportedPlatforms']
assert info['UIDeviceFamily'] == [1, 2]
assert '_opensidecar._tcp' in info['NSBonjourServices']
assert not (path.parent / 'embedded.mobileprovision').exists()
print({k:info.get(k) for k in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','MinimumOSVersion','UIDeviceFamily')})
PY
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
    lipo "$app/$executable" -verify_arch arm64
    check_no_upstream_endpoints "$app/$executable" >> dist/BUILD-INFO-iOS.txt
    mkdir -p "$RUNNER_TEMP/Payload"
    ditto "$app" "$RUNNER_TEMP/Payload/OpenAirDisplay.app"
    ditto -c -k --keepParent "$RUNNER_TEMP/Payload" "dist/OpenAirDisplay-iOS-unsigned-${suffix}.ipa"
    echo 'Unsigned device IPA; arm64 verified; re-sign before installing.' >> dist/BUILD-INFO-iOS.txt
    ;;
  *) echo "Unknown platform: $platform" >&2; exit 1 ;;
esac
lock='OpenSidecar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
if [[ -f "$lock" ]]; then
  printf '\nResolved Swift packages:\n' >> "dist/BUILD-INFO-${platform}.txt"
  cat "$lock" >> "dist/BUILD-INFO-${platform}.txt"
fi
python3 - "$platform" <<'PY'
import hashlib, sys, zipfile
from pathlib import Path
platform = sys.argv[1]
files = sorted(p for p in Path('dist').iterdir() if p.is_file())
for p in files:
    if p.suffix in ('.zip', '.ipa'):
        with zipfile.ZipFile(p) as z:
            assert z.testzip() is None, f'Corrupt ZIP: {p}'
            if p.suffix == '.ipa':
                assert 'Payload/OpenAirDisplay.app/Info.plist' in z.namelist()
Path(f'dist/SHA256SUMS-{platform}.txt').write_text(''.join(
    f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
print('\n'.join(f'{p.name}: {p.stat().st_size} bytes' for p in files))
PY
