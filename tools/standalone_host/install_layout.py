# SPDX-License-Identifier: GPL-3.0-only
"""Import legacy user settings into the permanent public installation once."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

LEGACY_KITS = ('.NDS_RC15', '.NDS_Standalone')
SETTINGS = ('NDS_v1.CFG', 'NDS_touch.cfg', 'NDS_stick.cfg', 'NDS_touchpad.cfg', 'NDS_speed.cfg',
            'NDS_video.cfg', 'NDS_graphics.cfg', 'NDS_pixel_grid.cfg', 'NDS_rtc.cfg')
LEGACY_LAUNCHERS = {
    'NDS_RC15.sh': '13a70273d2418a597209344054e603a9190a4c8b9c144b55668c9dce757bb040',
    'NDS4MiSTer.sh': '910feff43782bfcfdecaf39538033aa33aa4310bb97f6bde4cfa6d38936afca9',
}
RECEIPT = 'install-migration.json'


def read_regular(path):
    """Never follow a settings symlink or import a changing/oversized file."""
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > 1024 * 1024:
            raise ValueError('Invalid legacy settings file: ' + path.name)
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(1024 * 1024 + 1)
        after = os.fstat(fd)
        if len(data) != before.st_size or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('Legacy settings changed during import: ' + path.name)
        return data, before.st_mtime_ns
    finally:
        os.close(fd)


def sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_new(path, data, mtime_ns=None):
    if path.exists() or path.is_symlink():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink():
        raise ValueError('Settings directory must not be a symlink')
    fd, name = tempfile.mkstemp(prefix='.nds-import-', dir=str(path.parent))
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            os.fsync(stream.fileno())
        if mtime_ns is not None:
            os.utime(str(temporary), ns=(mtime_ns, mtime_ns))
        # The caller holds the supervisor lock. Existing stable settings win.
        if path.exists() or path.is_symlink():
            return False
        os.replace(str(temporary), str(path))
        sync_directory(path.parent)
        return True
    finally:
        if temporary.exists():
            temporary.unlink()


def archive_legacy_launchers(kit, scripts):
    archived = []
    for name, expected in LEGACY_LAUNCHERS.items():
        source = scripts / name
        if not source.is_file() or source.is_symlink():
            continue
        data, _ = read_regular(source)
        if hashlib.sha256(data).hexdigest() != expected:
            continue  # Preserve custom launchers and all private beta scripts.
        destination = kit / 'legacy-launchers' / (expected[:12] + '-' + name)
        write_new(destination, data)
        if read_regular(destination)[0] != data:
            raise ValueError('Legacy launcher backup differs: ' + name)
        source.unlink()
        sync_directory(scripts)
        archived.append(name)
    return archived


def migrate_legacy_settings(kit, sd_root):
    """Called after package/owner preflight, while holding the supervisor lock.

    The permanent directory wins; missing files prefer RC15, then RC14's
    .NDS_Standalone. Original settings and saves are never removed. A durable
    receipt prevents deleted/reset settings from reappearing on later launches.
    """
    kit, sd_root = Path(kit), Path(sd_root)
    scripts = sd_root / 'Scripts'
    if kit != scripts / '.NDS':
        return None
    if kit.is_symlink():
        raise ValueError('The NDS installation must not be a symlink')
    receipt = kit / RECEIPT
    if receipt.exists() or receipt.is_symlink():
        result = json.loads(read_regular(receipt)[0])
        if result.get('schema') != 1 or result.get('complete') is not True:
            raise ValueError('Incomplete NDS settings migration receipt')
    else:
        imported = {}
        for name in LEGACY_KITS:
            source = scripts / name
            if not source.is_dir() or source.is_symlink():
                continue
            candidates = [Path(n) for n in SETTINGS if (source / n).exists() or (source / n).is_symlink()]
            inputs = source / 'inputs'
            if inputs.is_dir() and not inputs.is_symlink():
                candidates += [Path('inputs') / p.name for p in sorted(inputs.glob('*.map'))]
            for relative in candidates:
                destination = kit / relative
                if destination.exists() or destination.is_symlink():
                    continue
                data, modified = read_regular(source / relative)
                if write_new(destination, data, modified):
                    imported[str(relative)] = dict(source=name, sha256=hashlib.sha256(data).hexdigest())
        result = dict(schema=1, complete=True, imported=imported)
        write_new(receipt, (json.dumps(result, indent=2, sort_keys=True) + '\n').encode())
    archived = archive_legacy_launchers(kit, scripts)
    return dict(result, archived_launchers=archived)
