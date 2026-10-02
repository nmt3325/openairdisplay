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

# Never let this AWDL fork auto-update itself back to the upstream app.
# These are build-only changes, recorded in BUILD-INFO; the source is retained.
if [[ "$platform" == macOS ]]; then
  python3 - <<'PY'
from pathlib import Path
for name in ('Mac/OpenSidecarMacApp.swift', 'MacReceiver/OpenSidecarMacReceiverApp.swift'):
    path = Path(name)
    text = path.read_text()
    anchor = 'startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil'
    assert text.count(anchor) == 1, f'Updater anchor changed: {name}'
    path.write_text(text.replace(anchor, anchor.replace('true', 'false', 1)))
PY
  echo 'Build-only change: upstream Sparkle updater disabled in both Mac apps.' >> dist/BUILD-INFO-macOS.txt
fi
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

case "$platform" in
  macOS)
    run_xcode tests test -scheme OpenSidecarMac -destination 'platform=macOS'
    for target in OpenSidecarMac OpenSidecarMacReceiver; do
      run_xcode "$target" build -scheme "$target" -configuration Release \
        -destination 'generic/platform=macOS' -sdk macosx \
        'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME=NO
      product='OpenDisplay'; asset='OpenDisplay'
      if [[ "$target" == OpenSidecarMacReceiver ]]; then
        product='OpenDisplay Receiver'; asset='OpenDisplayReceiver'
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
info['SUEnableAutomaticChecks'] = False
info['SUAutomaticallyUpdate'] = False
for key in ('SUFeedURL', 'SUPublicEDKey'):
    info.pop(key, None)
path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
print(sys.argv[1], {k:info.get(k) for k in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion')})
PY
      executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
      lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/$executable"
      codesign --force --deep --sign - "$app"
      codesign --verify --deep --strict --verbose=2 "$app"
      echo "${product}: ad-hoc signature verified; arm64 + x86_64 verified." >> dist/BUILD-INFO-macOS.txt
      ditto -c -k --keepParent "$app" "dist/${asset}-macOS-adhoc-universal-${suffix}.zip"
    done
    ;;
  iOS)
    run_xcode OpenSidecariOS build -scheme OpenSidecariOS -configuration Release \
      -destination 'generic/platform=iOS' -sdk iphoneos ONLY_ACTIVE_ARCH=NO
    app="$derived/Build/Products/Release-iphoneos/OpenSidecariOS.app"
    python3 - "$app" >> dist/BUILD-INFO-iOS.txt <<'PY'
import os, plistlib, sys
from pathlib import Path
path = Path(sys.argv[1]) / 'Info.plist'
info = plistlib.loads(path.read_bytes())
assert info['CFBundleShortVersionString'] == os.environ['APP_VERSION']
assert info['CFBundleVersion'] == os.environ['APP_BUILD_NUMBER']
assert 'iPhoneOS' in info['CFBundleSupportedPlatforms']
assert info['UIDeviceFamily'] == [1, 2]
assert '_opensidecar._tcp' in info['NSBonjourServices']
assert not (path.parent / 'embedded.mobileprovision').exists()
print({k:info.get(k) for k in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','MinimumOSVersion','UIDeviceFamily')})
PY
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
    lipo -verify_arch arm64 "$app/$executable"
    mkdir -p "$RUNNER_TEMP/Payload"
    ditto "$app" "$RUNNER_TEMP/Payload/OpenSidecariOS.app"
    ditto -c -k --keepParent "$RUNNER_TEMP/Payload" "dist/OpenDisplay-iOS-unsigned-${suffix}.ipa"
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
                assert 'Payload/OpenSidecariOS.app/Info.plist' in z.namelist()
Path(f'dist/SHA256SUMS-{platform}.txt').write_text(''.join(
    f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
print('\n'.join(f'{p.name}: {p.stat().st_size} bytes' for p in files))
PY
