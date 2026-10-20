import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('customer_provisioner', Path(__file__).parents[1] / 'customer_provisioner.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.env = {'RUPERT_CONTROL_PLANE_ORIGIN': 'https://control.example.org', 'RUPERT_PROVISIONER_TOKEN': 'x' * 64,
            'RUPERT_CUSTOMER_IMAGE': 'a' * 64, 'RUPERT_CUSTOMER_REVISION': 'b' * 40,
            'RUPERT_WORKSPACE_BASE_DOMAIN': 'workspaces.example.org'}
        self.job = {'id': 1, 'instance_id': '12345678-1234-1234-1234-123456789abc',
            'tenant_id': '87654321-4321-4321-4321-cba987654321', 'instance_name': 'rupert-customer-12345678-1234-1234-1234-123456789abc',
            'hostname': 'customer-one.workspaces.example.org', 'subdomain': 'customer-one', 'port': 24001,
            'google_subject': 'verified-subject', 'instance_secret': 'c' * 64, 'lease': 'lease'}
        self.calls = []
        self.instance = {'name': self.job['instance_name'], 'status': 'Running',
            'config': {'user.rupert.workspace_id': self.job['instance_id']},
            'expanded_config': {'security.privileged': 'false', 'security.nesting': 'false', 'security.idmap.isolated': 'true'},
            'expanded_devices': {'root': {'type': 'disk', 'path': '/', 'pool': 'default'}, 'eth0': {'type': 'nic', 'network': m.NETWORK}}}

    def run_command(self, args, payload=None, timeout=180):
        self.calls.append((args, payload))
        if args[1:3] == ['query', '/1.0/images/' + 'a' * 64]:
            return json.dumps({'properties': {'user.rupert.clean_template': 'true', 'user.rupert.revision': 'b' * 40}})
        if args[1] == 'list':
            return '[]'
        if args[1] == 'query':
            return json.dumps(self.instance)
        return ''

    def test_malicious_job_fields_are_rejected_before_any_host_command(self):
        worker = m.Worker(self.env, self.run_command)
        for field, value in [('hostname', 'evil.org'), ('instance_name', 'rupert'), ('port', '24001;cat /etc/shadow'), ('instance_id', '../rupert')]:
            with self.assertRaises(m.ProvisionError):
                worker.provision(dict(self.job, **{field: value}))
        self.assertFalse(self.calls)

    def test_rejects_privileged_nested_or_host_mounted_instances(self):
        worker = m.Worker(self.env, self.run_command)
        for field in ['security.privileged', 'security.nesting']:
            self.instance['expanded_config'][field] = 'true'
            with self.assertRaises(m.ProvisionError):
                worker.verify_policy(self.instance)
            self.instance['expanded_config'][field] = 'false'
        self.instance['expanded_devices']['hostfs'] = {'type': 'disk', 'path': '/host', 'source': '/'}
        with self.assertRaises(m.ProvisionError):
            worker.verify_policy(self.instance)

    def test_success_separates_secrets_from_process_arguments_and_checks_health_before_ready(self):
        worker = m.Worker(self.env, self.run_command)
        events = []
        worker.progress = lambda job, phase: events.append(phase)
        worker.check_health = lambda job, public: events.append('https-health' if public else 'local-health')
        worker.provision(self.job)
        self.assertEqual(['bootstrapping', 'checking', 'local-health', 'routing', 'https-health', 'complete'], events)
        for args, payload in self.calls:
            self.assertNotIn(self.job['instance_secret'], ' '.join(args))
        bootstrap = [payload for args, payload in self.calls if '/usr/local/libexec/rupert-customer-bootstrap' in args]
        self.assertEqual(self.job['instance_secret'], json.loads(bootstrap[0])['instance_secret'])
        self.assertTrue(any('security.idmap.isolated=true' in args for args, _ in self.calls))

    def test_unreviewed_image_is_never_used(self):
        def fake(args, **kwargs):
            self.calls.append(args)
            return json.dumps({'properties': {'user.rupert.clean_template': 'false'}})
        worker = m.Worker(self.env, fake)
        with self.assertRaises(m.ProvisionError) as error:
            worker.provision(self.job)
        self.assertEqual('image_unavailable', error.exception.code)
        self.assertEqual(1, len(self.calls))

    def test_quota_prevents_another_instance(self):
        def fake(args, **kwargs):
            if args[1] == 'list':
                return json.dumps([{'name': 'occupied-' + str(i)} for i in range(8)])
            return self.run_command(args, **kwargs)
        worker = m.Worker(self.env, fake)
        with self.assertRaises(m.ProvisionError) as error:
            worker.provision(self.job)
        self.assertEqual('quota_exceeded', error.exception.code)
        self.assertFalse(any('init' in args for args, _ in self.calls))


if __name__ == '__main__':
    unittest.main()
