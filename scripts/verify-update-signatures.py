#!/usr/bin/env python3
"""Require valid update signatures and reject archive/feed tampering."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

output, key = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
tool = Path('.build/artifacts/sparkle/Sparkle/bin/sign_update').resolve()
feed = output / 'appcast.xml'
enclosure = ET.parse(feed).find('./channel/item/enclosure')
archive = output / enclosure.attrib['url'].rsplit('/', 1)[1]
signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
subprocess.run([str(tool), '--ed-key-file', str(key), '--verify', str(archive), signature], check=True)
subprocess.run([str(tool), '--ed-key-file', str(key), '--verify', str(feed)], check=True)
with tempfile.TemporaryDirectory(prefix='shou-update-verification-') as temporary:
    base = Path(temporary)
    damaged = base / archive.name
    payload = bytearray(archive.read_bytes())
    payload[len(payload)//2] ^= 1
    damaged.write_bytes(payload)
    result = subprocess.run([str(tool), '--ed-key-file', str(key), '--verify', str(damaged), signature], capture_output=True)
    assert result.returncode != 0, 'Tampered update archive was accepted'
    damaged_feed = base / 'appcast.xml'
    damaged_feed.write_bytes(feed.read_bytes().replace(b'<title>', b'<title>tampered ', 1))
    result = subprocess.run([str(tool), '--ed-key-file', str(key), '--verify', str(damaged_feed)], capture_output=True)
    assert result.returncode != 0, 'Tampered update feed was accepted'
    public = plistlib.loads(Path('apps/macos/Info.plist').read_bytes())['SUPublicEDKey']
    verifier = base / 'verify.swift'
    verifier.write_text('''import Foundation
import CryptoKit
let key=try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[1])!)
let signature=Data(base64Encoded: CommandLine.arguments[2])!
let archive=try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
guard key.isValidSignature(signature, for: archive) else { fatalError("Embedded public key rejects release signature") }
guard !Curve25519.Signing.PrivateKey().publicKey.isValidSignature(signature, for: archive) else { fatalError("Wrong public key accepted") }
''')
    subprocess.run(['swift', str(verifier), public, signature, str(archive)], check=True)
print('Update signatures verified with embedded public key; modified archive, modified feed, and wrong key rejected.')
