#!/usr/bin/env python3
"""Installed only in a reviewed data-free customer image. Reads JSON from stdin."""
import json
import os
from pathlib import Path
import re
import secrets
import subprocess

APP = Path('/opt/rupert/web')
RUBY_BIN = '/opt/rbenv/versions/4.0.6/bin'


def main():
    payload = json.load(__import__('sys').stdin)
    for field in ('tenant_id', 'instance_id'):
        if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', payload[field]):
            raise ValueError('Invalid workspace identity')
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]*[a-z0-9]', payload['hostname']):
        raise ValueError('Invalid workspace hostname')
    if not re.fullmatch(r'https://[a-z0-9.-]+', payload['control_origin']):
        raise ValueError('Invalid control origin')
    if not re.fullmatch(r'[0-9a-f]{64}', payload['instance_secret']):
        raise ValueError('Invalid instance secret')
    if not re.fullmatch(r'[0-9a-f]{40}', payload['revision']):
        raise ValueError('Invalid revision')
    # Never import settings, databases, environment files or keys from production.
    env_path = Path('/etc/rupert.env')
    if env_path.exists():
        settings = dict(line.split('=', 1) for line in env_path.read_text().splitlines() if '=' in line)
        if settings.get('RUPERT_WORKSPACE_ID') != payload['instance_id'] or settings.get('RUPERT_INSTANCE_SECRET') != payload['instance_secret']:
            raise ValueError('Existing configuration belongs to another instance')
    else:
        settings = {
            'RAILS_ENV': 'production', 'RAILS_LOG_TO_STDOUT': '1', 'RAILS_SERVE_STATIC_FILES': '1',
            'RUPERT_NODE_MODE': 'workspace', 'RUPERT_TENANT_ID': payload['tenant_id'],
            'RUPERT_WORKSPACE_ID': payload['instance_id'], 'RUPERT_INSTANCE_HOSTNAME': payload['hostname'],
            'RUPERT_INSTANCE_SECRET': payload['instance_secret'], 'RUPERT_CONTROL_PLANE_ORIGIN': payload['control_origin'],
            'RUPERT_BUILD_SHA': payload['revision'], 'RUPERT_DB_ADAPTER': 'sqlite3',
            'RUPERT_SQLITE_DATABASE_PRODUCTION': '/var/lib/rupert/production.sqlite3',
            'SECRET_KEY_BASE': secrets.token_hex(64), 'RAILS_ENCRYPTION_PRIMARY_KEY': secrets.token_hex(32),
            'RAILS_ENCRYPTION_DETERMINISTIC_KEY': secrets.token_hex(32), 'RAILS_ENCRYPTION_KEY_DERIVATION_SALT': secrets.token_hex(32),
            'SHOPIFY_API_KEY': 'isolated-workspace-' + payload['instance_id'], 'SHOPIFY_API_SECRET': secrets.token_hex(32),
            'HOST': 'https://' + payload['hostname'], 'RAILS_MAX_THREADS': '3', 'JOB_THREADS': '1', 'JOB_CONCURRENCY': '1',
            'PATH': RUBY_BIN + ':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        }
        descriptor = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(''.join(key + '=' + value + '\n' for key, value in settings.items()))
    # systemd reads the private environment before switching to the app user.
    subprocess.run(['install', '-d', '-o', 'rupert', '-g', 'rupert', '-m', '0700', '/var/lib/rupert'], check=True)
    environment = {'PATH': settings['PATH'], 'HOME': '/var/lib/rupert', **settings}
    for args, body in [(['bundle', 'exec', 'rails', 'db:prepare'], None),
                       (['bundle', 'exec', 'rails', 'workspace:bootstrap'], json.dumps(payload))]:
        subprocess.run(['runuser', '-u', 'rupert', '--', *args], cwd=APP, env=environment, input=body, text=True, check=True)
    subprocess.run(['systemctl', 'enable', '--now', 'rupert-web', 'rupert-jobs', 'rupert-backup.timer'], check=True)
    print('Isolated workspace initialized.')


if __name__ == '__main__':
    main()
