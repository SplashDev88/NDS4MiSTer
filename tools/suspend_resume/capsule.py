#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One-slot persistence for the CPU checkpoint proof, NOT console save states.

The separate component-only magic deliberately cannot masquerade as a future
whole-machine image. This tool has no device connection or launcher integration.
"""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import struct
import tempfile

MAGIC = b'NDS4M-CPU-PROOF\x00\x01'
MAX_HEADER = 4096
MAX_PAYLOAD = 4096
MAX_FILE = len(MAGIC) + 4 + MAX_HEADER + MAX_PAYLOAD + 32
WORD_COUNTS = {'arm9-branch-v1': 68, 'arm7-branch-v1': 48}


class InvalidCheckpoint(ValueError):
    pass


def check_identity(identity):
    if not isinstance(identity, dict) or set(identity) != {'rom_sha256', 'build_sha256', 'component'}:
        raise InvalidCheckpoint('Exact ROM, build and component identity required')
    if identity['component'] not in WORD_COUNTS:
        raise InvalidCheckpoint('Unsupported component; full-machine resume is not implemented')
    for key in ('rom_sha256', 'build_sha256'):
        if not isinstance(identity[key], str) or re.fullmatch('[0-9a-f]{64}', identity[key]) is None:
            raise InvalidCheckpoint('Invalid identity digest: ' + key)


def check_payload(payload, identity):
    count = WORD_COUNTS[identity['component']]
    if not isinstance(payload, bytes) or len(payload) != 9 * count:
        raise InvalidCheckpoint('Incomplete CPU state word count')
    if re.fullmatch(rb'(?:[0-9A-F]{8}\n){' + str(count).encode() + rb'}', payload) is None:
        raise InvalidCheckpoint('Invalid CPU state encoding')


def encode(identity, payload):
    check_identity(identity)
    check_payload(payload, identity)
    header = json.dumps({'scope': 'cpu-component-only', 'identity': identity,
                         'payload_bytes': len(payload)}, sort_keys=True,
                        separators=(',', ':')).encode('ascii')
    body = MAGIC + struct.pack('<I', len(header)) + header + payload
    return body + hashlib.sha256(body).digest()


def decode(data, expected_identity):
    """Validate every byte and identity before returning state to any consumer."""
    check_identity(expected_identity)
    if not isinstance(data, bytes) or len(data) > MAX_FILE or len(data) < len(MAGIC) + 4 + 32:
        raise InvalidCheckpoint('Invalid checkpoint length')
    body, digest = data[:-32], data[-32:]
    if not hmac.compare_digest(hashlib.sha256(body).digest(), digest):
        raise InvalidCheckpoint('Checkpoint checksum failed')
    if body[:len(MAGIC)] != MAGIC:
        raise InvalidCheckpoint('Unsupported checkpoint format/version')
    size = struct.unpack_from('<I', body, len(MAGIC))[0]
    start = len(MAGIC) + 4
    if not 0 < size <= MAX_HEADER or start + size > len(body):
        raise InvalidCheckpoint('Invalid checkpoint header length')
    try:
        header = json.loads(body[start:start + size])
    except (UnicodeError, ValueError) as exc:
        raise InvalidCheckpoint('Invalid checkpoint metadata') from exc
    if not isinstance(header, dict) or set(header) != {'scope', 'identity', 'payload_bytes'}:
        raise InvalidCheckpoint('Unexpected checkpoint metadata')
    if header['scope'] != 'cpu-component-only':
        raise InvalidCheckpoint('Full-machine resume is not implemented')
    check_identity(header['identity'])
    if header['identity'] != expected_identity:
        raise InvalidCheckpoint('Checkpoint belongs to a different ROM, build or component')
    payload = body[start + size:]
    if type(header['payload_bytes']) is not int or len(payload) != header['payload_bytes']:
        raise InvalidCheckpoint('Checkpoint payload length mismatch')
    check_payload(payload, expected_identity)
    return payload


def read_slot(path, identity):
    with Path(path).open('rb') as stream:
        data = stream.read(MAX_FILE + 1)
    return decode(data, identity)


def write_slot(path, identity, payload):
    """Commit one complete image atomically; never truncate the current slot.

    The developer harness owns this directory and serializes all slot access.
    A directory-fsync failure after replace means durability is unconfirmed;
    callers must keep the running machine alive until this function succeeds.
    """
    data = encode(identity, payload)
    path = Path(path)
    if path.is_symlink():
        raise InvalidCheckpoint('Refusing a symlink slot')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.' + path.name + '.', dir=path.parent,
                                         delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # Read back the complete temporary image before committing it.
        if read_slot(temporary, identity) != payload:
            raise InvalidCheckpoint('Checkpoint read-back mismatch')
        os.replace(temporary, path)
        temporary = None
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['save', 'restore'])
    parser.add_argument('--identity', type=Path, required=True)
    parser.add_argument('--slot', type=Path, required=True)
    parser.add_argument('--words', type=Path, required=True)
    args = parser.parse_args()
    identity = json.loads(args.identity.read_text())
    if args.operation == 'save':
        write_slot(args.slot, identity, args.words.read_bytes())
    else:
        payload = read_slot(args.slot, identity)
        # Never replace a prior file or follow a link during extraction.
        with args.words.open('xb') as stream:
            stream.write(payload)


if __name__ == '__main__':
    main()
