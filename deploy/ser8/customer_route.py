#!/usr/bin/env python3
"""Install a single Caddy host route. Requires a reviewed top-level import.
No wildcard DNS or existing route is changed by this helper.
"""
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    hostname, port = sys.argv[1:]
    base = os.environ.get('RUPERT_WORKSPACE_BASE_DOMAIN', 'workspaces.rupertpos.com')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,61}[a-z0-9]\.' + re.escape(base), hostname):
        raise ValueError('Invalid hostname')
    if not port.isdecimal() or not 24000 < int(port) < 25000:
        raise ValueError('Invalid port')
    directory = Path('/etc/caddy/rupert-customers')
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Operator must prepare the customer route directory')
    # Top-level Caddyfile must explicitly import /etc/caddy/rupert-customers/*.caddy.
    config = Path('/etc/caddy/Caddyfile')
    if 'import /etc/caddy/rupert-customers/*.caddy' not in config.read_text():
        raise ValueError('The reviewed customer routing import is missing')
    with open('/run/lock/rupert-customer-routing.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        target = directory / (hostname + '.caddy')
        if target.is_symlink():
            raise ValueError('Refusing a symlink route')
        old = target.read_bytes() if target.exists() else None
        body = f'{hostname} {{\n  reverse_proxy 127.0.0.1:{port}\n}}\n'.encode()
        descriptor, name = tempfile.mkstemp(prefix='.pending-', dir=directory)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(body)
        os.chmod(name, 0o644)
        os.replace(name, target)
        try:
            subprocess.run(['caddy', 'validate', '--config', str(config)], check=True, capture_output=True)
            subprocess.run(['systemctl', 'reload', 'caddy'], check=True, capture_output=True)
        except Exception:
            if old is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(old)
            raise


if __name__ == '__main__':
    main()
