#!/usr/bin/env python3
"""Build a data-free image on SER8. Source is an exact public repository revision.
The running application is read only for the Ruby runtime, never for app data.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def run(args, body=None, timeout=600):
    return subprocess.run(args, input=body, text=True, capture_output=True, timeout=timeout, check=True).stdout


def main():
    revision, os_image = sys.argv[1:]
    if not re.fullmatch(r'[0-9a-f]{40}', revision) or not re.fullmatch(r'[0-9a-f]{64}', os_image):
        raise ValueError('An exact application revision and clean OS image fingerprint are required')
    name = 'rupert-image-build-' + revision[:12]
    existing = json.loads(run(['incus', 'list', '--format=json']))
    if any(item['name'] == name for item in existing):
        raise ValueError('Build instance already exists; inspect it before resuming')
    run(['incus', 'init', os_image, name, '-c', 'limits.cpu=1', '-c', 'limits.memory=2GiB', '-c', 'security.privileged=false', '-c', 'security.nesting=false'])
    run(['incus', 'start', name])
    print('Clean build instance started:', name, flush=True)
    run(['incus', 'exec', name, '--', 'bash', '-c', 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git sqlite3 libyaml-0-2 libgmp10 libcrypt1 libreadline8 libffi8 libzstd1 zlib1g'], timeout=600)
    # Copy only the public Ruby interpreter/gems. Never copy /opt/rupert, homes,
    # /etc/rupert.env, storage, uploads or any database from the live instance.
    with tempfile.TemporaryDirectory(prefix='rupert-public-runtime-') as directory:
        archive = Path(directory) / 'ruby.tar'
        with archive.open('wb') as stream:
            subprocess.run(['incus', 'exec', 'rupert', '--', 'tar', '-C', '/opt/rbenv/versions', '-cf', '-', '4.0.6'], stdout=stream, check=True)
        run(['incus', 'file', 'push', str(archive), name + '/tmp/rupert-public-ruby.tar'])
    script = r'''set -euo pipefail
install -d /opt/rbenv/versions
 tar -xf /tmp/rupert-public-ruby.tar -C /opt/rbenv/versions
rm /tmp/rupert-public-ruby.tar
export PATH=/opt/rbenv/versions/4.0.6/bin:$PATH
git clone -q https://github.com/techmore/rupert.git /opt/rupert
cd /opt/rupert
git checkout -q REVISION
[ "$(git rev-parse HEAD)" = REVISION ]
ruby bin/build-release-metadata
rm -rf .git
useradd --system --home-dir /var/lib/rupert --shell /usr/sbin/nologin rupert
install -Dm755 deploy/ser8/customer_bootstrap.py /usr/local/libexec/rupert-customer-bootstrap
install -Dm644 deploy/ser8/rupert-customer-web.service /etc/systemd/system/rupert-web.service
install -Dm644 deploy/rupert-jobs-ser8.service /etc/systemd/system/rupert-jobs.service
install -Dm644 deploy/rupert-backup-ser8.service /etc/systemd/system/rupert-backup.service
install -Dm644 deploy/rupert-backup-ser8.timer /etc/systemd/system/rupert-backup.timer
chmod 755 bin/backup.sh
cd web
bundle check
RAILS_ENV=production HOST=https://build.invalid SECRET_KEY_BASE=build-only RAILS_ENCRYPTION_PRIMARY_KEY=build-only-primary RAILS_ENCRYPTION_DETERMINISTIC_KEY=build-only-deterministic RAILS_ENCRYPTION_KEY_DERIVATION_SALT=build-only-salt bundle exec rails build:all
printf '{"revision":"REVISION"}\n' > config/build.json
rm -rf tmp/* log/* storage/*
install -d -o rupert -g rupert -m 700 tmp tmp/pids tmp/cache log storage /var/lib/rupert
chown -R root:root /opt/rupert
chown -R rupert:rupert tmp log storage
systemctl disable rupert-web rupert-jobs rupert-backup.timer ssh.service ssh.socket || true
rm -f /etc/ssh/ssh_host_* /etc/rupert.env
rm -rf /root/.ssh /home/ubuntu/.ssh /var/backups/rupert
find /opt/rupert -type f \( -name '.env' -o -name '*.sqlite3' -o -name '*.sqlite' \) -print | (! read)
[ ! -e /etc/rupert.env ]
[ -z "$(ls -A /var/lib/rupert)" ]
cloud-init clean --logs --machine-id || true
'''.replace('REVISION', revision)
    run(['incus', 'exec', name, '--', 'bash', '-s'], script, timeout=600)
    run(['incus', 'stop', name])
    output = run(['incus', 'publish', name, '--alias', 'rupert-customer-' + revision[:12],
        'user.rupert.clean_template=true', 'user.rupert.revision=' + revision], timeout=600)
    print(output.strip(), flush=True)
    print('Build instance retained for inspection. Remove it explicitly after image verification.', flush=True)


if __name__ == '__main__':
    main()
