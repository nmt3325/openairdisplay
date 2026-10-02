#!/usr/bin/env python3
"""Verify OpenAirDisplay release artifacts, publish them, update the feeds.

The macOS runner already verified its own output with codesign. This script is
the independent second opinion: it re-reads the artifacts offline, parses the
Mach-O code signatures itself, checks the Sparkle EdDSA signatures and only
then publishes. macOS keys privacy grants (TCC) to an app's designated
requirement, so the designated requirement is checked here as well.
"""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

import ed25519

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CONFIG = json.loads((HERE / 'config.json').read_text())
REPO = 'nmt3325/openairdisplay'
GITHUB = 'https://github.com/'
RAW = 'https://raw.githubusercontent.com/'
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
FEEDS = {'mac': 'public/openairdisplay-appcast.xml',
         'receiver': 'public/openairdisplay-appcast-receiver.xml'}
IOS_MANIFEST = 'public/openairdisplay-ios-version.json'
PEM_NAME = 'OpenAirDisplay-code-signing.pem'
BOT_NAME = 'github-actions[bot]'
BOT_EMAIL = '41898282+github-actions[bot]@users.noreply.github.com'
KEY_MARKERS = (b'-----BEGIN PRIVATE KEY', b'-----BEGIN RSA PRIVATE KEY',
               b'-----BEGIN EC PRIVATE KEY', b'-----BEGIN ENCRYPTED PRIVATE KEY')
CPU_NAMES = {0x01000007: 'x86_64', 0x0100000c: 'arm64'}
MAX_FEED_ITEMS = 10

PROBLEMS = []


def fail(message):
    PROBLEMS.append(message)
    print('FAIL: ' + message, flush=True)


def check(condition, message):
    if not condition:
        fail(message)
    return bool(condition)


def note(message):
    print('ok: ' + message, flush=True)


def run(args, capture=True):
    print('$ ' + ' '.join(args), flush=True)
    result = subprocess.run(args, text=True, capture_output=capture)
    if result.returncode != 0:
        if capture:
            sys.stderr.write((result.stdout or '') + (result.stderr or ''))
        raise SystemExit('Command failed: ' + ' '.join(args))
    return (result.stdout or '').strip()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def environment():
    env = {}
    for name in ('APP_VERSION', 'APP_BUILD_NUMBER', 'SOURCE_SHA', 'RELEASE_TAG'):
        env[name] = os.environ.get(name, '').strip()
        if not env[name]:
            raise SystemExit('Missing environment variable: ' + name)
    patterns = {'APP_VERSION': r'\d+\.\d+\.\d+', 'APP_BUILD_NUMBER': r'\d+',
                'SOURCE_SHA': r'[0-9a-f]{40}',
                # A release is named after the upstream version it is built
                # from, with this fork's suffix: upstream v1.25.0 -> v1.25.0-air.
                # Fork-only changes ship between upstream releases as a
                # revision: v1.25.0-air.2, .3, ... The upstream number must not
                # move for those, because no such upstream release exists.
                'RELEASE_TAG': r'v\d+\.\d+\.\d+-air(\.([2-9]|[1-9]\d+))?'}
    for name, pattern in patterns.items():
        if not re.fullmatch(pattern, env[name]):
            raise SystemExit('Malformed ' + name + ': ' + env[name])
    expected_tag = 'v' + env['APP_VERSION'] + '-air'
    if env['RELEASE_TAG'].split('-air')[0] != 'v' + env['APP_VERSION']:
        raise SystemExit('RELEASE_TAG ' + env['RELEASE_TAG'] + ' does not match '
                         'APP_VERSION ' + env['APP_VERSION']
                         + ' (expected ' + expected_tag + ' or '
                         + expected_tag + '.<revision>)')
    return env


def _der_element(data, pos, end):
    """Parse one element: (tag, body start, body end, next offset, definite).

    Apple's code signing CMS is BER with indefinite lengths, so 0x80 means
    "read children until the end-of-contents marker", not a one-byte length.
    """
    if pos + 2 > end:
        raise ValueError('Truncated DER element')
    tag = data[pos]
    first = data[pos + 1]
    if first == 0x80:
        if not tag & 0x20:
            raise ValueError('Indefinite length on a primitive element')
        body = pos + 2
        scan = body
        while True:
            if scan + 2 > end:
                raise ValueError('Unterminated indefinite-length element')
            if data[scan] == 0x00 and data[scan + 1] == 0x00:
                return tag, body, scan, scan + 2, False
            scan = _der_element(data, scan, end)[3]
    if first & 0x80:
        count = first & 0x7F
        if count == 0 or count > 4 or pos + 2 + count > end:
            raise ValueError('Unsupported DER length')
        length = int.from_bytes(data[pos + 2:pos + 2 + count], 'big')
        header = 2 + count
    else:
        length = first
        header = 2
    if pos + header + length > end:
        raise ValueError('DER element runs past its parent')
    return tag, pos + header, pos + header + length, pos + header + length, True


def _der_children(data, start, end):
    """Yield (tag, offset, body start, body end, definite) for one level."""
    pos = start
    while pos < end:
        if data[pos] == 0x00:      # end-of-contents marker, or blob padding
            return
        tag, body, body_end, following, definite = _der_element(data, pos, end)
        yield tag, pos, body, body_end, definite
        pos = following


def _looks_like_certificate(data, start, end):
    try:
        children = list(_der_children(data, start, end))
    except (ValueError, IndexError):
        return False
    tags = [child[0] for child in children]
    return tags == [0x30, 0x30, 0x03]


def certificate_fingerprints(der):
    """SHA-1 fingerprints of every X.509 certificate inside a CMS blob."""
    found = []

    def walk(start, end, depth):
        if depth > 12:
            return
        for tag, pos, body, body_end, definite in _der_children(der, start, end):
            if (tag == 0x30 and definite
                    and _looks_like_certificate(der, body, body_end)):
                found.append(hashlib.sha1(der[pos:body_end]).hexdigest())
                continue
            if tag & 0x20:
                walk(body, body_end, depth + 1)

    walk(0, len(der), 0)
    return found


def macho_slices(data):
    """Yield the file offset of every Mach-O image in a thin or fat file."""
    if len(data) < 8:
        raise ValueError('File is too small to be Mach-O')
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        wide = magic == 0xCAFEBABF
        count = struct.unpack_from('>I', data, 4)[0]
        if count > 32:
            raise ValueError('Implausible fat architecture count')
        stride = 32 if wide else 20
        for index in range(count):
            base = 8 + index * stride
            if wide:
                offset = struct.unpack_from('>Q', data, base + 8)[0]
            else:
                offset = struct.unpack_from('>I', data, base + 8)[0]
            yield int(offset)
        return
    yield 0


def macho_signature(data, offset):
    """Return (cpu type, embedded signature bytes) for one Mach-O image."""
    magic = struct.unpack_from('<I', data, offset)[0]
    if magic not in (0xFEEDFACE, 0xFEEDFACF):
        raise ValueError('Unsupported Mach-O magic 0x%08x' % magic)
    cpu_type = struct.unpack_from('<I', data, offset + 4)[0]
    commands = struct.unpack_from('<I', data, offset + 16)[0]
    pos = offset + (32 if magic == 0xFEEDFACF else 28)
    for _ in range(commands):
        command, size = struct.unpack_from('<II', data, pos)
        if size < 8:
            raise ValueError('Bad load command size')
        if command == 0x1D:
            start, length = struct.unpack_from('<II', data, pos + 8)
            return cpu_type, data[offset + start:offset + start + length]
        pos += size
    return cpu_type, b''


def super_blob(blob, magic_expected, what):
    """Split a code signing SuperBlob into its indexed sub-blobs."""
    magic, length, count = struct.unpack_from('>III', blob, 0)
    if magic != magic_expected:
        raise ValueError('Not %s: magic 0x%08x' % (what, magic))
    if length > len(blob):
        raise ValueError('%s is truncated' % what)
    entries = {}
    for index in range(count):
        slot, offset = struct.unpack_from('>II', blob, 12 + index * 8)
        sub_length = struct.unpack_from('>I', blob, offset + 4)[0]
        entries[slot] = blob[offset:offset + sub_length]
    return entries


def code_directory(blob):
    magic, _length, version, flags = struct.unpack_from('>IIII', blob, 0)
    if magic != 0xFADE0C02:
        raise ValueError('Not a code directory: magic 0x%08x' % magic)
    identifier_offset = struct.unpack_from('>I', blob, 20)[0]
    end = blob.index(b'\x00', identifier_offset)
    return {'version': version, 'flags': flags,
            'identifier': blob[identifier_offset:end].decode(),
            'cdhash': hashlib.sha256(blob).hexdigest()[:40]}


def _requirement_data(data, pos):
    length = struct.unpack_from('>I', data, pos)[0]
    pos += 4
    value = data[pos:pos + length]
    if len(value) != length:
        raise ValueError('Truncated requirement operand')
    return value, pos + length + (-length % 4)


def _requirement_expression(data, pos, found):
    """Walk one requirement expression; opcodes follow Apple's ExprOp order."""
    opcode = struct.unpack_from('>I', data, pos)[0] & 0x00FFFFFF
    pos += 4
    found['opcodes'].append(opcode)
    if opcode in (0, 1, 3):                        # False, True, AppleAnchor
        return pos
    if opcode == 2:                                # Ident
        value, pos = _requirement_data(data, pos)
        found['identifiers'].append(value.decode())
        return pos
    if opcode == 4:                                # AnchorHash
        slot = struct.unpack_from('>i', data, pos)[0]
        value, pos = _requirement_data(data, pos + 4)
        found['anchorHashes'].append((slot, value.hex()))
        return pos
    if opcode == 8:                                # CDHash
        value, pos = _requirement_data(data, pos)
        found['cdHashes'].append(value.hex())
        return pos
    if opcode in (6, 7):                           # And, Or
        return _requirement_expression(
            data, _requirement_expression(data, pos, found), found)
    if opcode == 9:                                # Not
        return _requirement_expression(data, pos, found)
    raise ValueError('Unsupported requirement opcode %d' % opcode)


def parse_requirement(blob):
    magic, length, kind = struct.unpack_from('>III', blob, 0)
    if magic != 0xFADE0C00:
        raise ValueError('Not a requirement: magic 0x%08x' % magic)
    if kind != 1:
        raise ValueError('Requirement kind %d is not an expression' % kind)
    found = {'opcodes': [], 'identifiers': [], 'anchorHashes': [], 'cdHashes': []}
    end = _requirement_expression(blob, 12, found)
    if end != length:
        raise ValueError('Requirement has %d trailing bytes' % (length - end))
    return found


def inspect_signed_macho(data, label, identifier, leaf_sha1):
    """Check every architecture of a signed Mach-O and return its arch names."""
    architectures = set()
    cdhashes = set()
    for offset in macho_slices(data):
        cpu_type, signature = macho_signature(data, offset)
        name = CPU_NAMES.get(cpu_type, hex(cpu_type))
        architectures.add(name)
        where = '%s (%s)' % (label, name)
        if not check(signature, where + ': no LC_CODE_SIGNATURE'):
            continue
        entries = super_blob(signature, 0xFADE0CC0, 'an embedded signature')
        if not check(0 in entries, where + ': no code directory'):
            continue
        directory = code_directory(entries[0])
        cdhashes.add(directory['cdhash'])
        check(not directory['flags'] & 0x0002,
              where + ': still ad hoc signed (flags 0x%x)' % directory['flags'])
        check(not directory['flags'] & 0x10000,
              where + ': hardened runtime is set (flags 0x%x)' % directory['flags'])
        check(directory['identifier'] == identifier,
              where + ': signed identifier is ' + directory['identifier'])
        wrapper = entries.get(0x10000, b'')
        if check(len(wrapper) > 8, where + ': no CMS signature, so it is not really signed'):
            fingerprints = certificate_fingerprints(wrapper[8:])
            check(fingerprints == [leaf_sha1],
                  where + ': embedded certificates are ' + repr(fingerprints))
        if not check(2 in entries, where + ': no internal requirements'):
            continue
        requirements = super_blob(entries[2], 0xFADE0C01, 'a requirements vector')
        if not check(3 in requirements, where + ': no designated requirement'):
            continue
        found = parse_requirement(requirements[3])
        check(found['identifiers'] == [identifier],
              where + ': the designated requirement names ' + repr(found['identifiers']))
        check(not found['cdHashes'],
              where + ': the designated requirement pins a cdhash, so an update '
                      'would lose every privacy grant')
        check([value for _slot, value in found['anchorHashes']] == [leaf_sha1],
              where + ': the designated requirement is pinned to '
              + repr(found['anchorHashes']))
    note(label + ': architectures ' + ', '.join(sorted(architectures))
         + '; cdhash ' + ', '.join(sorted(cdhashes)))
    return architectures


def scan_stream_for_keys(stream, where):
    tail = b''
    while True:
        block = stream.read(1 << 20)
        if not block:
            return
        window = tail + block
        for marker in KEY_MARKERS:
            if marker in window:
                fail(where + ': contains ' + marker.decode())
                return
        tail = window[-64:]


def scan_archive_for_keys(archive, label):
    for name in archive.namelist():
        if name.endswith('/'):
            continue
        lowered = name.lower()
        if lowered.endswith(('.p12', '.pfx', '.key')) or 'private' in lowered:
            fail(label + ': suspicious entry ' + name)
        with archive.open(name) as stream:
            scan_stream_for_keys(stream, label + '!' + name)


def feed_url(role):
    return RAW + REPO + '/main/' + FEEDS[role]


def download_url(tag, asset):
    return GITHUB + REPO + '/releases/download/' + tag + '/' + asset


def check_mac_archive(path, role, row, env):
    """Verify one signed macOS app archive against its update row."""
    label = path.name
    leaf = CONFIG['macSigningSHA1']
    identifier = CONFIG['bundleIDs'][role]
    with zipfile.ZipFile(path) as archive:
        if not check(archive.testzip() is None, label + ': the ZIP is corrupt'):
            return
        names = archive.namelist()
        tops = sorted({name.split('/')[0] for name in names})
        if not check(len(tops) == 1 and tops[0].endswith('.app'),
                     label + ': expected a single .app, found ' + repr(tops)):
            return
        app = tops[0]
        check(app + '/Contents/_CodeSignature/CodeResources' in names,
              label + ': no _CodeSignature, so the bundle seal is missing')
        check(any(name.startswith(app + '/Contents/Frameworks/Sparkle.framework/')
                  for name in names), label + ': Sparkle.framework is missing')
        info = plistlib.loads(archive.read(app + '/Contents/Info.plist'))
        expected = {'CFBundleIdentifier': identifier,
                    'CFBundleShortVersionString': env['APP_VERSION'],
                    'CFBundleVersion': env['APP_BUILD_NUMBER'],
                    'SUFeedURL': feed_url(role),
                    'SUPublicEDKey': CONFIG['sparklePublicKey']}
        for key, value in expected.items():
            check(info.get(key) == value, '%s: %s is %r, expected %r'
                  % (label, key, info.get(key), value))
        check(info.get('SUEnableAutomaticChecks') is True,
              label + ': automatic update checks are off')
        check(info.get('LSMinimumSystemVersion') == row['minimumSystemVersion'],
              '%s: LSMinimumSystemVersion %r does not match the update row %r'
              % (label, info.get('LSMinimumSystemVersion'), row['minimumSystemVersion']))
        executable = app + '/Contents/MacOS/' + info['CFBundleExecutable']
        if check(executable in names, label + ': no main executable'):
            try:
                architectures = inspect_signed_macho(
                    archive.read(executable), label, identifier, leaf)
            except (ValueError, IndexError, KeyError, struct.error) as error:
                fail(label + ': cannot parse the code signature: ' + str(error))
            else:
                check(architectures == {'arm64', 'x86_64'},
                      label + ': architectures are ' + repr(sorted(architectures)))
        scan_archive_for_keys(archive, label)


def check_ios_archive(path, env):
    """Verify the unsigned device IPA. It is deliberately not code signed."""
    label = path.name
    app = 'Payload/OpenAirDisplay.app/'
    with zipfile.ZipFile(path) as archive:
        if not check(archive.testzip() is None, label + ': the ZIP is corrupt'):
            return
        names = archive.namelist()
        if not check(app + 'Info.plist' in names, label + ': no app payload'):
            return
        check(app + 'embedded.mobileprovision' not in names,
              label + ': it still carries a provisioning profile')
        info = plistlib.loads(archive.read(app + 'Info.plist'))
        expected = {'CFBundleIdentifier': CONFIG['bundleIDs']['ios'],
                    'CFBundleShortVersionString': env['APP_VERSION'],
                    'CFBundleVersion': env['APP_BUILD_NUMBER']}
        for key, value in expected.items():
            check(info.get(key) == value, '%s: %s is %r, expected %r'
                  % (label, key, info.get(key), value))
        check('iPhoneOS' in (info.get('CFBundleSupportedPlatforms') or []),
              label + ': it is not an iOS device build')
        executable = app + info['CFBundleExecutable']
        if check(executable in names, label + ': no main executable'):
            data = archive.read(executable)
            architectures = set()
            for offset in macho_slices(data):
                cpu_type, _signature = macho_signature(data, offset)
                architectures.add(CPU_NAMES.get(cpu_type, hex(cpu_type)))
            check(architectures == {'arm64'},
                  label + ': architectures are ' + repr(sorted(architectures)))
        scan_archive_for_keys(archive, label)


def asset_names(env):
    suffix = env['APP_VERSION'] + '-' + env['SOURCE_SHA'][:7]
    return {'mac': 'OpenAirDisplay-macOS-signed-universal-' + suffix + '.zip',
            'receiver': 'OpenAirDisplayReceiver-macOS-signed-universal-'
                        + suffix + '.zip',
            'ios': 'OpenAirDisplay-iOS-unsigned-' + suffix + '.ipa'}


def verify_checksums(assets):
    """Re-check every per-platform SHA256SUMS file produced on the runner."""
    digests = {}
    for platform in ('macOS', 'iOS'):
        listing = assets / ('SHA256SUMS-' + platform + '.txt')
        if not check(listing.is_file(), 'Missing ' + listing.name):
            continue
        rows = [line for line in listing.read_text().splitlines() if line.strip()]
        check(rows, listing.name + ' is empty')
        for line in rows:
            digest, name = line.split('  ', 1)
            path = assets / name
            if not check(path.is_file(), listing.name + ' lists missing ' + name):
                continue
            actual = sha256_file(path)
            check(actual == digest, '%s: %s hashes to %s, not %s'
                  % (listing.name, name, actual, digest))
            digests[name] = digest
        note(listing.name + ': ' + str(len(rows)) + ' files verified')
    return digests


def verify_signing_certificate(assets):
    published = assets / PEM_NAME
    if not check(published.is_file(), 'Missing ' + PEM_NAME):
        return
    source = HERE / PEM_NAME
    check(published.read_bytes() == source.read_bytes(),
          PEM_NAME + ' does not match the certificate committed to the repository')
    body = re.sub(r'-----[A-Z ]+-----', '', published.read_text()).replace('\n', '')
    der = base64.b64decode(body, validate=True)
    fingerprint = hashlib.sha1(der).hexdigest()
    check(fingerprint == CONFIG['macSigningSHA1'],
          PEM_NAME + ' has SHA-1 ' + fingerprint + ', not the configured identity')
    check(hashlib.sha256(der).hexdigest() == CONFIG['macSigningSHA256'],
          PEM_NAME + ' does not match the configured SHA-256')
    note(PEM_NAME + ': matches the configured persistent identity')


def verify_update_rows(assets, env, names):
    """Check the Sparkle EdDSA signature and metadata of each macOS archive."""
    path = assets / 'MAC-UPDATES.json'
    if not check(path.is_file(), 'Missing MAC-UPDATES.json'):
        return {}
    rows = json.loads(path.read_text())
    public_key = base64.b64decode(CONFIG['sparklePublicKey'], validate=True)
    by_role = {}
    expected = {names['mac']: 'mac', names['receiver']: 'receiver'}
    check(sorted(row['asset'] for row in rows) == sorted(expected),
          'MAC-UPDATES.json lists ' + repr([row['asset'] for row in rows]))
    for row in rows:
        name = row['asset']
        role = expected.get(name)
        if not check(role, 'MAC-UPDATES.json has an unexpected asset ' + name):
            continue
        by_role[role] = row
        archive = assets / name
        if not check(archive.is_file(), 'Missing ' + name):
            continue
        check(row['length'] == archive.stat().st_size,
              name + ': the update row records length ' + str(row['length']))
        check(row['bundleID'] == CONFIG['bundleIDs'][role],
              name + ': the update row names bundle ID ' + row['bundleID'])
        check(row['version'] == env['APP_VERSION'],
              name + ': the update row says version ' + row['version'])
        check(row['buildNumber'] == env['APP_BUILD_NUMBER'],
              name + ': the update row says build ' + row['buildNumber'])
        check(row['sourceSHA'] == env['SOURCE_SHA'],
              name + ': the update row says commit ' + row['sourceSHA'])
        signature = base64.b64decode(row['signature'], validate=True)
        if check(len(signature) == 64, name + ': the EdDSA signature is malformed'):
            check(ed25519.verify(public_key, archive.read_bytes(), signature),
                  name + ': the EdDSA signature does not match the fork update key')
    note('MAC-UPDATES.json: update signatures verified against the fork key')
    return by_role


def verify_identity_proofs(assets):
    """Check the runner's codesign evidence that the DR survives an update."""
    leaf = CONFIG['macSigningSHA1']
    for asset, role in (('OpenAirDisplay', 'mac'),
                        ('OpenAirDisplayReceiver', 'receiver')):
        path = assets / ('IDENTITY-' + asset + '.json')
        if not check(path.is_file(), 'Missing ' + path.name):
            continue
        proof = json.loads(path.read_text())
        bundle = CONFIG['bundleIDs'][role]
        check(proof['bundleID'] == bundle,
              path.name + ': bundle ID is ' + proof['bundleID'])
        check(proof['authority'] == 'OpenAirDisplay Persistent Code Signing',
              path.name + ': signer is ' + proof['authority'])
        check(proof['certificateSHA1'] == leaf,
              path.name + ': certificate is ' + proof['certificateSHA1'])
        check(proof['certificateChainLength'] == 1,
              path.name + ': unexpected certificate chain length')
        requirement = proof['designatedRequirement']
        check('identifier "' + bundle + '"' in requirement,
              path.name + ': the DR does not pin the bundle ID: ' + requirement)
        check(leaf in requirement.lower().replace(':', ''),
              path.name + ': the DR does not pin the certificate: ' + requirement)
        check('cdhash' not in requirement.lower(),
              path.name + ': the DR pins a cdhash: ' + requirement)
        flags = proof['codeDirectoryFlags'] or ''
        check('adhoc' not in flags and 'runtime' not in flags,
              path.name + ': code directory flags are ' + flags)
        check(proof['updateProbeSatisfiesDesignatedRequirement'] is True,
              path.name + ': the simulated update failed the DR')
        check(proof['cdhash'] and proof['updateProbeCDHash']
              and proof['cdhash'] != proof['updateProbeCDHash'],
              path.name + ': the simulated update did not change the CDHash, '
                          'so the proof is meaningless')
        note(path.name + ': stable designated requirement proven on the runner')


def _notes_head():
    identifiers = CONFIG['bundleIDs']
    upstream = 'v' + CONFIG['appVersion']
    return [
        'OpenAirDisplay rebuilt on upstream OpenDisplay ' + upstream + '. Fork releases'
        ' are named after the upstream version they are built from, plus `-air`.',
        '',
        "## What's Changed",
        '',
        '- Rebased onto upstream ['
        + upstream + '](' + GITHUB + 'peetzweg/opendisplay/releases/tag/' + upstream
        + '), so everything upstream shipped up to that release is included.',
        '- Apple peer-to-peer WiFi (AWDL) is re-applied on top: a direct WiFi link to'
        ' the iPad or iPhone without a router, shown as `AWDL` in the performance'
        ' overlay. Upstream\'s cable/WiFi detection is kept alongside it.',
        '- The app icon is this fork\'s red mark.',
        '- The apps ship as `' + identifiers['mac'] + '`, `' + identifiers['receiver']
        + '` and `' + identifiers['ios'] + '`, so they install alongside OpenDisplay'
        ' instead of replacing it.',
        '- Updates are served from this fork\'s own Sparkle feeds and are signed with'
        ' this fork\'s own EdDSA key. Nothing points at upstream any more, and CI'
        ' greps the linked binaries to prove it.',
        '- Every macOS build is signed with one persistent certificate, and its'
        ' designated requirement is pinned to that certificate plus the bundle ID.',
        '- The release itself is built, signed, verified and published by'
        ' `.github/workflows/fork-release.yml`, which refuses to publish anything it'
        ' cannot verify twice.',
        '',
        '## Why the signature matters',
        '',
        'macOS stores Accessibility, Screen Recording and Local Network grants against'
        ' an app\'s designated requirement. Ad hoc signed builds get a requirement'
        ' containing their own code hash, so every new build looks like a different'
        ' app and the grants fall away. These builds use a designated requirement of'
        ' `identifier "<bundle id>" and certificate leaf = H"'
        + CONFIG['macSigningSHA1'] + '"`, which contains no code hash at all.',
        '',
        'CI proves the property rather than asserting it: it re-signs a copy of each'
        ' app with a different build number, then requires that the copy still'
        ' satisfies the original designated requirement and that its code hash did'
        ' change. Both apps passed. This has not been tested against real TCC state on'
        ' a Mac, so treat the first launch as a one-time re-grant.',
    ]


def release_notes(env, names):
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    run_line = (GITHUB + REPO + '/actions/runs/' + run_id) if run_id else 'local run'
    lines = _notes_head() + [
        '',
        '## Requirements',
        '',
        '- OpenAirDisplay for Mac: macOS 14 or newer',
        '- OpenAirDisplay Receiver: macOS 12 or newer',
        '- OpenAirDisplay for iPhone and iPad: iOS 15 or newer',
        '',
        '## Install',
        '',
        'The Mac builds are signed with a self-issued certificate and are not'
        ' notarised, so Gatekeeper will object the first time. Right-click the app and'
        ' choose Open, or allow it under System Settings > Privacy & Security after the'
        ' first attempt. If macOS refuses outright, clear the quarantine flag:',
        '',
        '```',
        'xattr -dr com.apple.quarantine /Applications/OpenAirDisplay.app',
        '```',
        '',
        '- Coming from OpenDisplay: grant Accessibility, Screen Recording and Local'
        ' Network once to OpenAirDisplay, because the bundle identifiers differ.'
        ' Updating from an earlier OpenAirDisplay release keeps those grants, since'
        ' the bundle identifiers and the signing certificate are unchanged.',
        '- An existing OpenDisplay install is untouched and keeps updating from'
        ' upstream. Remove it if you do not want two copies.',
        '- The IPA is unsigned. Re-sign it with your own identity (for example with'
        ' Sideloadly or AltStore) before installing it on a device.',
        '',
        '## Checksums',
        '',
        '`SHA256SUMS.txt` lists the SHA-256 of every asset in this release, and'
        ' `OpenAirDisplay-code-signing.pem` is the public certificate the Mac builds'
        ' are signed with (SHA-1 `' + CONFIG['macSigningSHA1'] + '`).',
        '',
        '## Build provenance',
        '',
        '- Source commit: `' + env['SOURCE_SHA'] + '`',
        '- Build number: `' + env['APP_BUILD_NUMBER'] + '` (app version '
        + env['APP_VERSION'] + ')',
        '- Workflow run: ' + run_line,
        '- `BUILD-INFO-macOS.txt` and `BUILD-INFO-iOS.txt` record the toolchain,'
        ' resolved packages and signature evidence.',
        '',
        'Fork of [peetzweg/opendisplay](' + GITHUB + 'peetzweg/opendisplay).',
        '']
    return '\n'.join(lines)


def gh(args, capture=True):
    return run(['gh'] + args, capture=capture)


def release_title(env):
    # Everything before the suffix is the upstream release this is built from;
    # a trailing .2, .3 ... is this fork's own revision of that same base.
    upstream = env['RELEASE_TAG'].split('-air')[0]
    return ('OpenAirDisplay ' + env['RELEASE_TAG'] + ' - upstream OpenDisplay '
            + upstream + ' plus peer-to-peer WiFi, own identity and own updates')


def write_combined_checksums(assets, uploads):
    path = assets / 'SHA256SUMS.txt'
    path.write_text(''.join(sha256_file(item) + '  ' + item.name + '\n'
                            for item in uploads))
    note('SHA256SUMS.txt: ' + str(len(uploads)) + ' assets')
    return path


def publish_release(env, uploads, notes, dry_run):
    tag = env['RELEASE_TAG']
    files = [str(item) for item in uploads]
    if dry_run:
        note('dry run: would publish ' + tag + ' with '
             + ', '.join(item.name for item in uploads))
        return
    exists = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO],
                            text=True, capture_output=True).returncode == 0
    if exists:
        at_tag = gh(['api', 'repos/' + REPO + '/commits/' + tag, '--jq', '.sha'])
        if at_tag != env['SOURCE_SHA']:
            raise SystemExit('Tag ' + tag + ' already points at ' + at_tag)
        gh(['release', 'upload', tag, '--repo', REPO, '--clobber'] + files)
        gh(['release', 'edit', tag, '--repo', REPO, '--title', release_title(env),
            '--notes-file', str(notes), '--latest'])
    else:
        gh(['release', 'create', tag, '--repo', REPO, '--target', env['SOURCE_SHA'],
            '--title', release_title(env), '--notes-file', str(notes),
            '--latest'] + files)
    note('published ' + tag)


def verify_published_assets(env, uploads, workspace):
    """Download the release back and compare it with what we uploaded."""
    tag = env['RELEASE_TAG']
    directory = workspace / 'verify-download'
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    gh(['release', 'download', tag, '--repo', REPO, '--dir', str(directory)])
    for item in uploads:
        copy = directory / item.name
        if not check(copy.is_file(), tag + ': ' + item.name + ' is not on the release'):
            continue
        check(sha256_file(copy) == sha256_file(item),
              tag + ': the published ' + item.name + ' differs from the built one')
    extra = sorted(path.name for path in directory.iterdir()
                   if path.name not in {item.name for item in uploads})
    check(not extra, tag + ': unexpected assets on the release: ' + repr(extra))
    latest = gh(['api', 'repos/' + REPO + '/releases/latest', '--jq', '.tag_name'])
    check(latest == tag, 'releases/latest points at ' + latest + ', not ' + tag)
    note(tag + ': every published asset matches the verified build')


def appcast_item(env, role, row, asset):
    product = 'OpenAirDisplay' if role == 'mac' else 'OpenAirDisplay Receiver'
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = product + ' ' + env['APP_VERSION']
    ET.SubElement(item, 'link').text = GITHUB + REPO + '/releases/tag/' + env['RELEASE_TAG']
    ET.SubElement(item, '{%s}version' % SPARKLE_NS).text = env['APP_BUILD_NUMBER']
    ET.SubElement(item, '{%s}shortVersionString' % SPARKLE_NS).text = env['APP_VERSION']
    ET.SubElement(item, '{%s}minimumSystemVersion' % SPARKLE_NS).text = \
        row['minimumSystemVersion']
    ET.SubElement(item, 'description').text = (
        '<p>' + product + ' ' + env['APP_VERSION'] + ' (build '
        + env['APP_BUILD_NUMBER'] + '). Release notes: '
        + GITHUB + REPO + '/releases/tag/' + env['RELEASE_TAG'] + '</p>')
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, 'enclosure', {
        'url': download_url(env['RELEASE_TAG'], asset),
        'length': str(row['length']),
        'type': 'application/octet-stream',
        '{%s}edSignature' % SPARKLE_NS: row['signature']})
    return item


def render_appcast(path, env, role, row, asset):
    """Prepend this build to a feed, keeping the channel and recent history."""
    ET.register_namespace('sparkle', SPARKLE_NS)
    root = ET.parse(path).getroot()
    channel = root.find('channel')
    if channel is None:
        raise SystemExit(path.name + ' has no channel element')
    items = channel.findall('item')
    for existing in items:
        version = existing.find('{%s}version' % SPARKLE_NS)
        if version is not None and version.text == env['APP_BUILD_NUMBER']:
            channel.remove(existing)
    remaining = channel.findall('item')
    position = list(channel).index(remaining[0]) if remaining else len(list(channel))
    channel.insert(position, appcast_item(env, role, row, asset))
    for stale in channel.findall('item')[MAX_FEED_ITEMS:]:
        channel.remove(stale)
    path.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                    + ET.tostring(root, encoding='unicode') + '\n')


def feed_changes(env, names, rows):
    for role in ('mac', 'receiver'):
        render_appcast(ROOT / FEEDS[role], env, role, rows[role], names[role])
    manifest = ROOT / IOS_MANIFEST
    data = json.loads(manifest.read_text())
    data['ios']['recommendedVersion'] = env['APP_VERSION']
    data['ios']['storeURL'] = GITHUB + REPO + '/releases/latest'
    manifest.write_text(json.dumps(data, indent=2) + '\n')
    return [FEEDS['mac'], FEEDS['receiver'], IOS_MANIFEST]


def confirm_pushed_feeds(paths, commit):
    remote = run(['git', 'ls-remote', 'origin', 'refs/heads/main']).split()[0]
    check(remote == commit, 'origin/main is ' + remote + ', not the feed commit')
    for relative in paths:
        encoded = gh(['api', 'repos/' + REPO + '/contents/' + relative
                      + '?ref=' + commit, '--jq', '.content'])
        published = base64.b64decode(encoded)
        check(published == (ROOT / relative).read_bytes(),
              relative + ' on origin/main differs from what was committed')
    note('update feeds live on main at ' + commit)


def update_feeds(env, names, rows, dry_run):
    message = ('release: OpenAirDisplay ' + env['RELEASE_TAG']
               + ' update feeds [skip ci]')
    for attempt in range(1, 4):
        run(['git', 'fetch', '--quiet', 'origin', 'main'])
        run(['git', 'checkout', '--force', '-B', 'openairdisplay-feeds', 'FETCH_HEAD'])
        paths = feed_changes(env, names, rows)
        if not run(['git', 'status', '--porcelain', '--'] + paths):
            note('the update feeds already describe this build')
            return
        if dry_run:
            print(run(['git', 'diff', '--'] + paths))
            return
        run(['git', 'add', '--'] + paths)
        run(['git', '-c', 'user.name=' + BOT_NAME, '-c', 'user.email=' + BOT_EMAIL,
             'commit', '--quiet', '-m', message, '--'] + paths)
        pushed = subprocess.run(['git', 'push', 'origin', 'HEAD:refs/heads/main'],
                                text=True, capture_output=True)
        if pushed.returncode == 0:
            confirm_pushed_feeds(paths, run(['git', 'rev-parse', 'HEAD']))
            return
        sys.stderr.write(pushed.stderr)
        print('push attempt ' + str(attempt) + ' lost the race; retrying', flush=True)
        time.sleep(5 * attempt)
    raise SystemExit('Could not push the updated feeds')


def stop_if_unverified(stage):
    if PROBLEMS:
        print('')
        for problem in PROBLEMS:
            print('- ' + problem)
        raise SystemExit('%d problem(s) %s; see above' % (len(PROBLEMS), stage))


def main():
    parser = argparse.ArgumentParser(description='Publish an OpenAirDisplay release')
    parser.add_argument('assets', type=Path, help='Directory of build artifacts')
    parser.add_argument('--dry-run', action='store_true',
                        help='Verify everything, publish nothing')
    parser.add_argument('--skip-feeds', action='store_true',
                        help='Do not touch the update feeds')
    options = parser.parse_args()
    env = environment()
    assets = options.assets.resolve()
    if not assets.is_dir():
        raise SystemExit('No such directory: ' + str(assets))
    names = asset_names(env)
    print('Verifying ' + env['RELEASE_TAG'] + ' built from '
          + env['SOURCE_SHA'] + ' (build ' + env['APP_BUILD_NUMBER'] + ')', flush=True)
    verify_checksums(assets)
    verify_signing_certificate(assets)
    rows = verify_update_rows(assets, env, names)
    verify_identity_proofs(assets)
    for role in ('mac', 'receiver'):
        archive = assets / names[role]
        if archive.is_file() and role in rows:
            check_mac_archive(archive, role, rows[role], env)
        else:
            fail('Cannot verify ' + names[role] + ' without its archive and update row')
    ipa = assets / names['ios']
    if check(ipa.is_file(), 'Missing ' + names['ios']):
        check_ios_archive(ipa, env)
    uploads = [assets / names['mac'], assets / names['receiver'], ipa,
               assets / PEM_NAME, assets / 'BUILD-INFO-macOS.txt',
               assets / 'BUILD-INFO-iOS.txt']
    for item in uploads:
        check(item.is_file(), 'Missing release asset ' + item.name)
        if item.is_file() and item.suffix in ('.txt', '.pem'):
            with open(item, 'rb') as handle:
                scan_stream_for_keys(handle, item.name)
    stop_if_unverified('before publishing; nothing was uploaded')
    notes = assets / 'RELEASE-NOTES.md'
    notes.write_text(release_notes(env, names))
    uploads.append(write_combined_checksums(assets, uploads))
    publish_release(env, uploads, notes, options.dry_run)
    if not options.dry_run:
        verify_published_assets(env, uploads, assets.parent)
    if options.skip_feeds:
        note('skipping the update feeds on request')
    else:
        update_feeds(env, names, rows, options.dry_run)
    stop_if_unverified('after publishing; the release needs attention')
    print('Done: ' + env['RELEASE_TAG'], flush=True)


if __name__ == '__main__':
    main()
