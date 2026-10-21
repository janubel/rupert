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
    'sqlite3': '#!/bin/sh\necho "sqlite3 $*" >> "$CALLS"\nset -- $2\ntouch "$2"\n',
    'bundle': '#!/bin/sh\necho "bundle $*" >> "$CALLS"\ncase "$*" in *db:migrate*) exit "${MIGRATE_EXIT:-0}" ;; esac\n',
    'chown': '#!/bin/sh\necho "chown $*" >> "$CALLS"\n',
    'sleep': '#!/bin/sh\n',
}


def check_runs(*runs):
    return {'check_runs': [{'id': i, 'name': n, 'conclusion': c} for i, (n, c) in enumerate(runs)]}


GREEN = check_runs(('CI (sqlite3)', 'success'))


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
        }
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

    def test_up_to_date_does_nothing(self):
        result, calls = self.run_deploy()
        self.assertEqual(result.returncode, 0)
        self.assertIn('up to date', result.stdout)
        self.assertNotIn('systemctl', calls)

    def test_green_ci_deploys_after_backup(self):
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
        for checks, word in [(check_runs(), 'pending'),
                             (check_runs(('CI (sqlite3)', 'failure')), 'red')]:
            self.set_checks(checks)
            result, calls = self.run_deploy()
            self.assertIn(f'is {word}, not deploying', result.stdout)
            self.assertEqual(self.head(self.tmp / 'app'), self.old)

    def test_rerun_that_passed_supersedes_earlier_failure(self):
        self.commit('feature')
        self.set_checks(check_runs(('CI (sqlite3)', 'failure'), ('CI (sqlite3)', 'success')))
        result, _ = self.run_deploy()
        self.assertIn('healthy', result.stdout)

    def test_dirty_checkout_is_skipped(self):
        self.commit('feature')
        (self.tmp / 'app' / 'stray.txt').write_text('x')
        result, _ = self.run_deploy()
        self.assertIn('dirty', result.stdout)
        self.assertEqual(self.head(self.tmp / 'app'), self.old)

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


if __name__ == '__main__':
    unittest.main()
