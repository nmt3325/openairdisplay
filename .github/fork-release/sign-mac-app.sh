#!/usr/bin/env bash
# Sign one macOS app with the persistent OpenAirDisplay identity and prove that
# a changed build keeps the same designated requirement (DR). macOS privacy
# grants (TCC) are keyed to that DR, so a stable DR keeps them across updates.
# Written for /bin/bash 3.2 as well as newer bash.
set -euo pipefail
app="${1:?App path}"; asset="${2:?Asset name}"
: "${MAC_SIGNING_IDENTITY:?}" "${MAC_SIGNING_KEYCHAIN:?}" "${APP_BUILD_NUMBER:?}" "${RUNNER_TEMP:?}"
die() { echo "::error::$*" >&2; exit 1; }
first() { sed -n 1p; }
config=.github/fork-release/config.json
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
role=mac
if [[ "$asset" == OpenAirDisplayReceiver ]]; then role=receiver; fi
expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundleIDs"][sys.argv[2]])' "$config" "$role")
[[ "$bundle" == "$expected" ]] || die "$app has bundle ID $bundle, expected $expected"
case "$bundle" in com.peetzweg.*) die "Upstream bundle ID: $bundle" ;; esac
id_lower=$(printf '%s' "$MAC_SIGNING_IDENTITY" | tr '[:upper:]' '[:lower:]')
[[ "$id_lower" =~ ^[0-9a-f]{40}$ ]] || die 'MAC_SIGNING_IDENTITY must be a certificate SHA-1'

expression="identifier \"${bundle}\" and certificate leaf = H\"${id_lower}\""
# codesign treats -r/-R arguments as file paths unless they start with "=".
requirement="=designated => ${expression}"
sign() {
  codesign --force --sign "$MAC_SIGNING_IDENTITY" --keychain "$MAC_SIGNING_KEYCHAIN" \
    --timestamp=none "$@"
}
# Nested Sparkle code first (each keeps its own identifier); then pin only the
# outer app's DR. Applying the outer DR with --deep would break nested IDs.
sign --deep "$app"
sign --identifier "$bundle" --requirements "$requirement" "$app"
codesign --verify --deep --strict --verbose=2 -R "=${expression}" "$app"
for arch in arm64 x86_64; do
  codesign --verify --strict -a "$arch" -R "=${expression}" "$app"
done

details=$(codesign -d --verbose=4 "$app" 2>&1)
signer=$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | first)
identifier=$(printf '%s\n' "$details" | sed -n 's/^Identifier=//p' | first)
old_hash=$(printf '%s\n' "$details" | sed -n 's/^CDHash=//p' | first)
flags=$(printf '%s\n' "$details" | sed -n 's/^CodeDirectory .* flags=\([^ ]*\).*/\1/p' | first)
[[ "$signer" == 'OpenAirDisplay Persistent Code Signing' ]] || die "Unexpected signer: ${signer:-none}"
[[ "$identifier" == "$bundle" ]] || die "Signed identifier ${identifier:-none} is not $bundle"
[[ -n "$old_hash" ]] || die "No CDHash for $app"
case "$details" in *Signature=adhoc*) die "$app is still ad hoc signed" ;; esac
case "$flags" in *adhoc*|*runtime*) die "Unexpected code directory flags: $flags" ;; esac
framework="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" ]] || die "Sparkle.framework is missing from $app"
nested=$(codesign -d --verbose=2 "$framework" 2>&1 | sed -n 's/^Authority=//p' | first)
[[ "$nested" == "$signer" ]] || die "Sparkle.framework is signed by ${nested:-nobody}"

dr=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p' | first)
dr_lower=$(printf '%s' "$dr" | tr '[:upper:]' '[:lower:]')
case "$dr_lower" in *cdhash*|'') die "Unstable DR: ${dr:-none}" ;; esac
case "$dr_lower" in *"certificate leaf = h\"${id_lower}\""*) ;; *) die "DR not pinned to the certificate: $dr" ;; esac
case "$dr" in *"identifier \"${bundle}\""*) ;; *) die "DR not pinned to the bundle ID: $dr" ;; esac

# Simulate the next update: change the build number, sign again, and require
# that the new build still satisfies the DR recorded for this one. That is the
# check TCC makes before it reuses a privacy grant.
probe="$RUNNER_TEMP/${asset}-update-probe.app"
rm -rf "$probe"
ditto "$app" "$probe"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((APP_BUILD_NUMBER + 1000))" "$probe/Contents/Info.plist"
sign --identifier "$bundle" --requirements "$requirement" "$probe"
codesign --verify --deep --strict -R "=${dr}" "$probe"
probe_dr=$(codesign -d -r- "$probe" 2>&1 | sed -n 's/^designated => //p' | first)
probe_hash=$(codesign -d --verbose=4 "$probe" 2>&1 | sed -n 's/^CDHash=//p' | first)
[[ "$probe_dr" == "$dr" ]] || die "The update probe changed the DR: $probe_dr"
[[ -n "$probe_hash" && "$probe_hash" != "$old_hash" ]] || die 'The update probe kept the same CDHash'

prefix="$RUNNER_TEMP/${asset}-certificate-"
rm -f "$prefix"*
codesign -d --extract-certificates="$prefix" "$app" >/dev/null 2>&1
[[ -s "${prefix}0" ]] || die "No certificate is embedded in $app"
leaf=$(openssl x509 -inform DER -in "${prefix}0" -noout -fingerprint -sha1 | sed 's/^.*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')
[[ "$leaf" == "$id_lower" ]] || die "Embedded leaf certificate is $leaf, expected $id_lower"
chain=0
while [[ -e "${prefix}${chain}" ]]; do chain=$((chain + 1)); done

export PROOF_ASSET="$asset" PROOF_BUNDLE="$bundle" PROOF_SIGNER="$signer" PROOF_LEAF="$leaf" \
  PROOF_CHAIN="$chain" PROOF_DR="$dr" PROOF_FLAGS="$flags" PROOF_HASH="$old_hash" PROOF_PROBE_HASH="$probe_hash"
python3 - <<'PY'
import json, os
from pathlib import Path
env = os.environ
proof = {
    'asset': env['PROOF_ASSET'],
    'bundleID': env['PROOF_BUNDLE'],
    'authority': env['PROOF_SIGNER'],
    'certificateSHA1': env['PROOF_LEAF'],
    'certificateChainLength': int(env['PROOF_CHAIN']),
    'designatedRequirement': env['PROOF_DR'],
    'codeDirectoryFlags': env['PROOF_FLAGS'],
    'cdhash': env['PROOF_HASH'],
    'updateProbeCDHash': env['PROOF_PROBE_HASH'],
    'updateProbeSatisfiesDesignatedRequirement': True,
}
Path('dist').mkdir(exist_ok=True)
Path('dist', 'IDENTITY-%s.json' % proof['asset']).write_text(json.dumps(proof, indent=2) + '\n')
with open('dist/BUILD-INFO-macOS.txt', 'a') as info:
    info.write('Code signature: %s\n' % json.dumps(proof, sort_keys=True))
PY
rm -rf "$probe" "$prefix"*
echo "Signed ${bundle} with ${signer}; DR: ${dr}"
