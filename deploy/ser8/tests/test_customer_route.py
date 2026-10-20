import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('customer_route', Path(__file__).parents[1] / 'customer_route.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RouteTest(unittest.TestCase):
    def test_explicit_host_listener_is_preserved(self):
        with patch.dict(m.os.environ, {'RUPERT_CUSTOMER_BIND_ADDRESS': '192.0.2.10'}):
            self.assertIn(b'  bind 192.0.2.10\n', m.route_body('customer.example.org', '24001'))

    def test_bind_setting_cannot_inject_caddy_configuration(self):
        with patch.dict(m.os.environ, {'RUPERT_CUSTOMER_BIND_ADDRESS': '192.0.2.10\nrespond secret'}):
            with self.assertRaises(ValueError):
                m.route_body('customer.example.org', '24001')
