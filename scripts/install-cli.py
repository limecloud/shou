#!/usr/bin/env python3
"""Install a user-level CLI entry that executes the chosen packaged binary."""
from pathlib import Path
import argparse
import json
import os
import shlex
import subprocess
import tempfile


def install(executable, bin_directory):
    executable = executable.expanduser().resolve(strict=True)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('Choose an executable Shou CLI file.')
    # Executing the real path preserves SwiftPM's adjacent resource lookup.
    # A symlink to the executable can instead load a developer build fallback.
    version = subprocess.check_output([str(executable), '--version'], text=True, timeout=15).strip()
    if not version.startswith('shou '):
        raise ValueError('The selected executable is not the Shou CLI.')
    skill = json.loads(subprocess.check_output([str(executable), 'agent', 'skill', '--json'], text=True, timeout=15))['data']
    if not Path(skill['entrypoint']).resolve().is_relative_to(executable.parent):
        raise ValueError('The selected CLI does not resolve its adjacent Skill resources. Use a packaged distribution.')
    bin_directory = bin_directory.expanduser().absolute()
    if '..' in bin_directory.parts or any(p.is_symlink() for p in (bin_directory, *bin_directory.parents)):
        raise ValueError('Choose a real bin directory without symbolic links or traversal.')
    bin_directory.mkdir(parents=True, exist_ok=True)
    destination = bin_directory / 'shou'
    content = ('#!/bin/sh\n# Managed by Shou CLI installer.\nexec ' + shlex.quote(str(executable)) + ' "$@"\n').encode()
    if destination.is_symlink():
        raise FileExistsError('The existing shou entry is a link; it was preserved. Choose another bin directory.')
    if destination.exists():
        if not destination.is_file() or destination.read_bytes() != content or not os.access(destination, os.X_OK):
            raise FileExistsError('The existing shou entry differs; it was preserved. Choose another bin directory.')
        state = 'already_current'
    else:
        with tempfile.NamedTemporaryFile(prefix='.shou-install-', dir=bin_directory) as staged:
            staged.write(content)
            staged.flush()
            os.fchmod(staged.fileno(), 0o755)
            # Hard-link publication refuses to overwrite an entry created meanwhile.
            os.link(staged.name, destination)
        state = 'installed'
    return {'state': state, 'launcher': str(destination), 'executable': str(executable),
            'version': version, 'on_path': str(bin_directory) in os.environ.get('PATH', '').split(os.pathsep)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, default=Path('/Applications/Shou.app/Contents/Helpers/shou'))
    parser.add_argument('--bin-directory', type=Path, default=Path.home() / '.local/bin')
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.executable, args.bin_directory)))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'CLI installation failed: {error}\n')


if __name__ == '__main__':
    main()
