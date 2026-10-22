import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / 'rupert-autodeploy.sh'

# Stand-ins for the host tools. Each records its call in $CALLS; curl serves the
# check-runs JSON from $CHECKS and answers the health check with $HEALTH.
STUBS = {
    'curl': '''#!/bin/sh
echo "curl $*" >> "$CALLS"
case "$*" in *check-runs*) cat "$CHECKS" ;; *) printf %s "$HEALTH" ;; esac
''',
    'systemctl': '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\n',
    'sqlite3': '#!/bin/sh\necho "sqlite3 $*" >> "$CALLS"\n[ "${BACKUP_EXIT:-0}" = 0 ] || exit "$BACKUP_EXIT"\nset -- $2\ntouch "$2"\n',
    'bundle': '#!/bin/sh\necho "bundle $*" >> "$CALLS"\ncase "$*" in *db:migrate*) exit "${MIGRATE_EXIT:-0}" ;; *assets:precompile*) exit "${ASSETS_EXIT:-0}" ;; esac\n[ "$1" = install ] && exit "${INSTALL_EXIT:-0}"\n',
    'chown': '#!/bin/sh\necho "chown $*" >> "$CALLS"\n',
    'sleep': '#!/bin/sh\n',
}


def check_runs(*runs):
    return {'check_runs': [{'id': i, 'name': n, 'status': 'completed' if c else 'in_progress', 'conclusion': c}
                           for i, (n, c) in enumerate(runs)]}


REQUIRED = ('CI (sqlite3)', 'Product site consistency', 'Dependency and static scan')
GREEN = check_runs(*[(name, 'success') for name in REQUIRED])


class AutodeployTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        for name, body in STUBS.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        (self.tmp / 'rupert.env').write_text('')
        self.calls = self.tmp / 'calls'
        self.checks = self.tmp / 'checks.json'
        self.set_checks(GREEN)
        self.env = {
            'HOME': str(self.tmp), 'CALLS': str(self.calls), 'CHECKS': str(self.checks), 'HEALTH': '200',
            'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.org',
            'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.org',
            'RUPERT_AUTODEPLOY_APP': str(self.tmp / 'app'),
            'RUPERT_AUTODEPLOY_BACKUPS': str(self.tmp / 'backups'),
            'RUPERT_AUTODEPLOY_STATE': str(self.tmp / 'state'),
            'RUPERT_AUTODEPLOY_LOCK': str(self.tmp / 'lock'),
            'RUPERT_AUTODEPLOY_ENV_FILE': str(self.tmp / 'rupert.env'),
            'RUPERT_AUTODEPLOY_PATH': f'{bin_dir}:/usr/bin:/bin',
            'RUPERT_AUTODEPLOY_INBOX': str(self.tmp / 'inbox'),
        }
        self.inbox = self.tmp / 'inbox'
        self.inbox.mkdir()
        self.origin = self.tmp / 'origin'
        self.git('init', '-q', '-b', 'main', str(self.origin))
        (self.origin / 'web' / 'storage').mkdir(parents=True)
        (self.origin / 'web' / 'storage' / '.keep').write_text('')
        self.commit('initial')
        self.git('clone', '-q', str(self.origin), str(self.tmp / 'app'))
        self.old = self.head(self.tmp / 'app')

    def git(self, *args, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd, env={**os.environ, **self.env}, check=True,
                              capture_output=True, text=True).stdout.strip()

    def head(self, repo):
        return self.git('rev-parse', 'HEAD', cwd=repo)

    def commit(self, message, path='web/app.txt'):
        (self.origin / path).parent.mkdir(parents=True, exist_ok=True)
        (self.origin / path).write_text(message)
        self.git('add', '-A', cwd=self.origin)
        self.git('commit', '-q', '-m', message, cwd=self.origin)
        return self.head(self.origin)

    def set_checks(self, data):
        self.checks.write_text(json.dumps(data))

    def run_deploy(self, **env):
        if self.calls.exists():
            self.calls.unlink()
        result = subprocess.run(['bash', str(SCRIPT)], env={**self.env, **env}, capture_output=True, text=True)
        calls = self.calls.read_text() if self.calls.exists() else ''
        return result, calls

    def status(self, name='status.json'):
        return json.loads((self.tmp / 'state' / name).read_text())

    def request_install(self, at):
        path = self.inbox / 'install-requested'
        path.write_text('')
        os.utime(path, (at, at))

    def test_up_to_date_does_nothing(self):
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn('up to date', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_all_exact_sha_checks_green_deploys_after_backup(self):
        new = self.commit('feature')
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), new)
        self.assertLess(calls.index('sqlite3'), calls.index('db:migrate'))
        self.assertIn('systemctl restart rupert-web rupert-jobs', calls)

    def test_deployed_files_stay_readable_by_the_app_user(self):
        # Regression: umask 077 made Gemfile.lock and new gems root-only and the
        # app (running as another user) could not boot.
        new = self.commit('gem update', path='web/Gemfile.lock')
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(self.tmp / 'app'), new)
        mode = (self.tmp / 'app' / 'web' / 'Gemfile.lock').stat().st_mode
        self.assertTrue(mode & 0o004, oct(mode))
        self.assertEqual((self.tmp / 'backups').stat().st_mode & 0o777, 0o700)

    def test_pending_or_red_ci_is_not_deployed(self):
        self.commit('feature')
        for checks, word in [(check_runs(('Product site consistency', 'success')), 'pending'),
                             (check_runs(('CI (sqlite3)', 'failure')), 'red'),
                             (check_runs(('CI (sqlite3)', 'success'), ('Product site consistency', 'success'),
                                         ('Dependency and static scan', 'skipped')), 'red'),
                             (check_runs(('CI (sqlite3)', 'success'), ('Product site consistency', 'success')),
                              'pending')]:
            self.set_checks(checks)
            result, calls = self.run_deploy()
            self.assertIn(f'is {word}, not deploying', result.stdout)
            self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_rerun_that_passed_supersedes_earlier_failure(self):
        self.commit('feature')
        self.set_checks(check_runs(('CI (sqlite3)', 'failure'), ('CI (sqlite3)', 'success'),
                                   ('Product site consistency', 'success'), ('Dependency and static scan', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_mobile_changes_require_the_exact_sha_mobile_check(self):
        self.commit('mobile change', path='mobile/src/task.js')
        result, _ = self.run_deploy()
        self.assertIn('is pending, not deploying', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

        self.set_checks(check_runs(*[(name, 'success') for name in REQUIRED], ('validate', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_retired_postgresql_check_is_ignored(self):
        self.commit('feature')
        self.set_checks(check_runs(('CI (postgresql)', 'failure'), ('CI (sqlite3)', 'success'),
                                   ('Product site consistency', 'success'), ('Dependency and static scan', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_dirty_checkout_is_skipped(self):
        self.commit('feature')
        (self.tmp / 'app' / 'stray.txt').write_text('x')
        result, _ = self.run_deploy()
        self.assertIn('dirty', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_diverged_checkout_is_not_reset_or_deployed(self):
        app = self.tmp / 'app'
        (app / 'local.txt').write_text('local commit')
        self.git('add', 'local.txt', cwd=app)
        self.git('commit', '-q', '-m', 'local only', cwd=app)
        local = self.head(app)
        self.commit('remote only')

        result, calls = self.run_deploy()

        self.assertIn('not a fast-forward', result.stdout)
        self.assertEqual(self.head(app), local)
        self.assertNotIn('systemctl restart', calls)

    def test_existing_deploy_lock_prevents_overlapping_install(self):
        self.commit('feature')
        with self.open_lock():
            result, calls = self.run_deploy()

        self.assertIn('another deploy is running', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertNotIn('sqlite3', calls)

    def open_lock(self):
        handle = open(self.tmp / 'lock', 'w')
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(handle.close)
        return handle

    def test_backup_failure_stops_before_checkout_or_build(self):
        self.commit('feature')

        result, calls = self.run_deploy(BACKUP_EXIT='1')

        self.assertEqual(result.returncode, 1)
        self.assertIn('backup failed, aborting', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertNotIn('db:migrate', calls)

    def test_asset_build_failure_rolls_back_code(self):
        self.commit('feature')

        result, _ = self.run_deploy(ASSETS_EXIT='1')

        self.assertEqual(result.returncode, 1)
        self.assertIn('no new migrations', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_shallow_checkout_is_completed_before_deploying(self):
        shutil.rmtree(self.tmp / 'app')
        self.git('clone', '-q', '--depth', '1', f'file://{self.origin}', str(self.tmp / 'app'))
        new = self.commit('feature')
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=self.tmp / 'app'), 'true')
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=self.tmp / 'app'), 'false')

    def test_dry_run_changes_nothing(self):
        self.commit('feature')
        result, calls = self.run_deploy(DRY_RUN='1')
        self.assertIn('dry run', result.stdout)
        self.assertNotIn('sqlite3', calls)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_failed_deploy_rolls_back_and_is_not_retried(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        result, calls = self.run_deploy(MIGRATE_EXIT='1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('1 migration(s) may have run', result.stdout)
        self.assertIn('rollback healthy', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertIn('chown', calls)

        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn(f'{new[:8]} already failed', result.stdout)
        self.assertNotIn('systemctl', calls)

        fixed = self.commit('fix')
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {fixed[:8]}, healthy', result.stdout)
        self.assertFalse((self.tmp / 'state' / 'failed-sha').exists())

    def test_unhealthy_deploy_rolls_back(self):
        self.commit('feature')
        result, _ = self.run_deploy(HEALTH='502')
        self.assertEqual(result.returncode, 1)
        self.assertIn('no new migrations', result.stdout)
        self.assertIn('ROLLBACK ALSO UNHEALTHY', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)
        self.assertEqual(self.status('last-deploy.json')['state'], 'failed')
        self.assertIn('needs a human', self.status()['message'])

    def test_status_is_reported_to_the_app_and_readable_by_it(self):
        result, _ = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        status = self.status()
        self.assertEqual((status['state'], status['current'], status['mode']), ('up_to_date', self.old, 'automatic'))
        self.assertFalse(status['install_requested'])
        self.assertEqual((self.tmp / 'state').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.tmp / 'state' / 'status.json').stat().st_mode & 0o777, 0o644)

        self.set_checks(check_runs(('CI (sqlite3)', 'failure')))
        new = self.commit('feature')
        self.run_deploy()
        self.assertEqual((self.status()['state'], self.status()['target']), ('ci_failed', new))

        self.set_checks(GREEN)
        self.run_deploy()
        self.assertEqual(self.status()['state'], 'deployed')
        self.assertEqual((self.status('last-deploy.json')['state'], self.status('last-deploy.json')['target']), ('deployed', new))

    def test_dry_run_reports_nothing(self):
        self.commit('feature')
        self.run_deploy(DRY_RUN='1')
        self.assertFalse((self.tmp / 'state' / 'status.json').exists())

    def test_manual_mode_waits_for_a_request_then_installs_once(self):
        (self.inbox / 'manual').write_text('')
        new = self.commit('feature')
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn('ready to install', result.stdout)
        self.assertNotIn('systemctl', calls)
        self.assertEqual((self.status()['state'], self.status()['mode']), ('ready', 'manual'))
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

        self.request_install(1_800_000_000)
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertFalse(self.status()['install_requested'])

        # The same request is spent: the next commit waits for a new one.
        self.commit('another')
        result, calls = self.run_deploy()
        self.assertIn('ready to install', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_request_waits_for_green_ci(self):
        (self.inbox / 'manual').write_text('')
        self.set_checks(check_runs(('Product site consistency', 'success')))
        new = self.commit('feature')
        self.request_install(1_800_000_000)
        self.run_deploy()
        self.assertEqual(self.status()['state'], 'waiting_ci')
        self.assertTrue(self.status()['install_requested'])

        self.set_checks(GREEN)
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)

    def test_request_while_up_to_date_does_not_approve_a_later_commit(self):
        (self.inbox / 'manual').write_text('')
        self.request_install(1_800_000_000)
        self.run_deploy()
        self.commit('feature')
        result, calls = self.run_deploy()
        self.assertIn('ready to install', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_request_retries_a_failed_commit_once(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        self.assertEqual(self.status()['state'], 'failed')
        self.assertEqual(self.status('last-deploy.json')['state'], 'failed')

        self.request_install(1_800_000_000)
        result, _ = self.run_deploy()
        self.assertIn(f'deployed {new[:8]}, healthy', result.stdout)
        self.assertFalse((self.tmp / 'state' / 'failed-sha').exists())

    def test_failed_retry_is_not_repeated_by_the_same_request(self):
        new = self.commit('broken migration', path='web/db/migrate/20261020000000_broken.rb')
        self.run_deploy(MIGRATE_EXIT='1')
        self.request_install(1_800_000_000)
        self.run_deploy(MIGRATE_EXIT='1')
        result, calls = self.run_deploy(MIGRATE_EXIT='1')
        self.assertIn(f'{new[:8]} already failed', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_inbox_files_are_never_followed_or_changed(self):
        secret = self.tmp / 'secret'
        secret.write_text('do not read')
        (self.inbox / 'install-requested').symlink_to(secret)
        self.run_deploy()
        self.assertTrue((self.inbox / 'install-requested').is_symlink())
        self.assertEqual(secret.read_text(), 'do not read')
        self.assertNotIn('do not read', (self.tmp / 'state' / 'status.json').read_text())


if __name__ == '__main__':
    unittest.main()
