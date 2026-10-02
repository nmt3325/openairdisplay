#!/usr/bin/env bash
# Import the persistent OpenAirDisplay signing identity and Sparkle update key
# into a throwaway keychain on the macOS runner. Never create replacements in
# CI: a new certificate changes the designated requirement and resets privacy
# grants, and a new Sparkle key makes installed copies reject every update.
set -euo pipefail
: "${MAC_P12:?Persistent signing certificate is required}"
: "${MAC_P12_PASSWORD:?}" "${SPARKLE_PRIVATE_KEY:?}" "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"
die() { echo "::error::$*" >&2; exit 1; }
umask 077
config=.github/fork-release/config.json
cert=.github/fork-release/OpenAirDisplay-code-signing.pem
private_dir="$RUNNER_TEMP/openairdisplay-private"
mkdir -p "$private_dir"
export PRIVATE_DIR="$private_dir"
python3 - <<'PY'
import base64, json, os, secrets, sys
from pathlib import Path
sys.path.insert(0, '.github/fork-release')
import ed25519
p = Path(os.environ['PRIVATE_DIR'])
config = json.load(open('.github/fork-release/config.json'))
p12 = base64.b64decode(''.join(os.environ['MAC_P12'].split()), validate=True)
assert p12[:1] == b'\x30', 'OPENAIRDISPLAY_MAC_SIGNING_P12 is not a base64 PKCS#12 file'
p.joinpath('identity.p12').write_bytes(p12)
password = os.environ['MAC_P12_PASSWORD'].strip('\r\n')
assert password, 'OPENAIRDISPLAY_MAC_SIGNING_PASSWORD is empty'
p.joinpath('identity-password.txt').write_text(password)
key = ''.join(os.environ['SPARKLE_PRIVATE_KEY'].split())
seed = base64.b64decode(key, validate=True)
assert len(seed) == 32, 'Use the persistent 32-byte Sparkle seed; never generate one in CI'
public = base64.b64encode(ed25519.public_key_from_seed(seed)).decode()
assert public == config['sparklePublicKey'], 'Sparkle key does not match SUPublicEDKey'
p.joinpath('sparkle-private.txt').write_text(key)
p.joinpath('keychain-password.txt').write_text(secrets.token_urlsafe(32))
print('Sparkle key matches the public key built into the apps.')
PY
keychain="$private_dir/signing.keychain-db"
password=$(cat "$private_dir/keychain-password.txt")
identity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["macSigningSHA1"])' "$config")
actual=$(openssl x509 -in "$cert" -noout -fingerprint -sha1 | sed 's/^.*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')
[[ "$actual" == "$identity" ]] || die "Repository certificate $actual does not match config.json ($identity)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$private_dir/identity.p12" -k "$keychain" -f pkcs12 \
  -P "$(cat "$private_dir/identity-password.txt")" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# Put the keychain on the search list so codesign finds the identity and chain.
existing=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
# shellcheck disable=SC2086
security list-keychains -d user -s "$keychain" $existing
# Trust is not needed to sign or to check the pinned DR, so never block on it.
sudo -n security authorizationdb write com.apple.trust-settings.admin allow >/dev/null 2>&1 || true
if perl -e 'alarm shift; exec @ARGV' 60 sudo -n security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$cert" >/dev/null 2>&1; then
  echo 'Runner trusts the OpenAirDisplay certificate for code signing.'
else
  echo '::notice::Runner trust settings unchanged; signing does not depend on them.'
fi
identities=$(security find-identity -p codesigning "$keychain")
printf '%s\n' "$identities"
case "$(printf '%s' "$identities" | tr '[:upper:]' '[:lower:]')" in
  *"$identity"*) ;;
  *) die "Signing identity $identity is not in $keychain" ;;
esac
probe="$private_dir/codesign-probe"
cp /usr/bin/true "$probe"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$probe"
codesign --verify --strict -R "=certificate leaf = H\"${identity}\"" "$probe"
rm -f "$probe"
echo 'Signing with the persistent identity works.'

version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sparkleVersion"])' "$config")
tools="$RUNNER_TEMP/openairdisplay-sparkle-tools"
archive="$RUNNER_TEMP/openairdisplay-sparkle.tar.xz"
mkdir -p "$tools"
sparkle_repo='https://github.com/sparkle-project/Sparkle'
release_url=$(printf '%s/releases/download/%s/Sparkle-%s.tar.xz' "$sparkle_repo" "$version" "$version")
curl -fsSL --retry 3 -o "$archive" "$release_url"
python3 - "$archive" <<'VERIFY'
import hashlib, json, sys
expected = json.load(open('.github/fork-release/config.json'))['sparkleToolsSHA256']
actual = hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest()
assert actual == expected, 'Sparkle tools checksum %s != %s' % (actual, expected)
VERIFY
tar -xf "$archive" -C "$tools"
sign_update="$tools/bin/sign_update"
[[ -x "$sign_update" ]] || sign_update=$(find "$tools" -type f -name sign_update | sed -n 1p)
[[ -n "$sign_update" && -x "$sign_update" ]] || die "sign_update is missing from Sparkle ${version}"
{
  echo "MAC_SIGNING_KEYCHAIN=$keychain"
  echo "MAC_SIGNING_IDENTITY=$identity"
  echo "SPARKLE_PRIVATE_KEY_FILE=$private_dir/sparkle-private.txt"
  echo "SPARKLE_SIGN_UPDATE=$sign_update"
} >> "$GITHUB_ENV"
