import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

path = Path(__file__).parents[1] / 'rupert-logs'
loader = importlib.machinery.SourceFileLoader('rupert_logs', str(path))
spec = importlib.util.spec_from_loader('rupert_logs', loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

R1 = 'aaaaaaaa-1111-2222-3333-444444444444'
R2 = 'bbbbbbbb-1111-2222-3333-444444444444'
LINES = [
    '* Puma starting in single mode...',
    json.dumps({'ts': 't1', 'level': 'info', 'event': 'request', 'request_id': R1, 'method': 'GET', 'path': '/dashboard', 'status': 200, 'user_id': 7}),
    '<4>' + json.dumps({'ts': 't2', 'level': 'warn', 'event': 'upload', 'request_id': R2, 'files': [{'size': 3, 'sha256': 'abc'}], 'outcome': 'rejected'}),
    json.dumps({'ts': 't3', 'level': 'warn', 'event': 'import', 'request_id': R2, 'kind': 'bank_statement', 'outcome': 'rejected'}),
    json.dumps({'ts': 't4', 'level': 'warn', 'event': 'request', 'request_id': R2, 'method': 'POST', 'path': '/bank_statements', 'status': 422, 'user_id': 8, 'slow': True}),
    json.dumps({'ts': 't5', 'level': 'info', 'event': 'noise_summary', 'total': 40, 'items': []}),
    '{"broken json',
]


def run(*argv):
    with tempfile.NamedTemporaryFile('w', suffix='.log', delete=False) as handle:
        handle.write('\n'.join(LINES) + '\n')
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        m.main(['--file', handle.name, *argv])
    Path(handle.name).unlink()
    return out.getvalue().splitlines()


class RupertLogsTest(unittest.TestCase):
    def test_request_matches_a_prefix_and_shows_every_line_of_that_request(self):
        lines = run('request', R2[:8])
        self.assertEqual(3, len(lines))
        self.assertTrue(all('[bbbbbbbb]' in line for line in lines))

    def test_request_needs_enough_of_the_id(self):
        with self.assertRaises(SystemExit):
            run('request', 'bbb')

    def test_user_filters_by_user_id(self):
        lines = run('user', '7')
        self.assertEqual(1, len(lines))
        self.assertIn('/dashboard', lines[0])

    def test_upload_shows_the_upload_with_its_import_and_request(self):
        lines = run('upload')
        self.assertTrue(lines[0].startswith('--- upload'))
        self.assertEqual(['upload', 'import', 'request'], [line.split()[2] for line in lines[1:]])

    def test_errors_slow_and_noise(self):
        self.assertEqual(3, len(run('errors')))
        self.assertEqual(1, len(run('slow')))
        self.assertEqual(1, len(run('noise')))

    def test_json_prints_the_raw_line_and_non_json_lines_are_skipped(self):
        lines = run('--json', 'tail')
        self.assertEqual(5, len(lines))
        self.assertEqual('request', json.loads(lines[0])['event'])
        self.assertEqual('upload', json.loads(lines[1])['event'])


if __name__ == '__main__':
    unittest.main()
