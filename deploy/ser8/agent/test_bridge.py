import importlib.util
import os
import sys
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('bridge', os.path.join(os.path.dirname(__file__), 'rupert_mcp_bridge.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

CHANNEL = '61d13f21-6b96-4ac4-ae80-ee9dd455a500'


class BridgeTest(unittest.TestCase):
    def test_tools_outside_the_allow_list_are_refused_and_never_forwarded(self):
        with mock.patch.object(bridge, 'rupert_call') as forwarded:
            for name in ('create_task', 'ai_health', 'recent_errors', 'list_feedback', 'report_context', 'ls', ''):
                result = bridge.call_tool(name, {})
                self.assertTrue(result['isError'], name)
            forwarded.assert_not_called()

    def test_allowed_tools_are_forwarded(self):
        upstream = {'result': {'content': [{'type': 'text', 'text': 'ok'}], 'isError': False}}
        with mock.patch.object(bridge, 'rupert_call', return_value=upstream) as forwarded:
            self.assertEqual(bridge.call_tool('sales_summary', {'from': '2026-10-01'}), upstream['result'])
            self.assertEqual(forwarded.call_args[0][0]['params']['name'], 'sales_summary')

    def test_list_only_offers_allowed_tools_plus_reply(self):
        listed = {'result': {'tools': [{'name': n} for n in ('sales_summary', 'create_task', 'ai_health', 'submit_feedback')]}}
        with mock.patch.object(bridge, 'rupert_call', return_value=listed):
            names = [t['name'] for t in bridge.list_tools()]
        self.assertEqual(names, ['buzz_reply', 'sales_summary', 'submit_feedback'])

    def test_reply_tool_survives_an_unreachable_rupert(self):
        with mock.patch.object(bridge, 'rupert_call', side_effect=OSError('down')):
            self.assertEqual([t['name'] for t in bridge.list_tools()], ['buzz_reply'])

    def test_reply_validates_channel_text_and_thread(self):
        with mock.patch.object(bridge.subprocess, 'run') as run:
            self.assertTrue(bridge.buzz_reply({'channel': 'general; rm -rf /', 'content': 'x'})['isError'])
            self.assertTrue(bridge.buzz_reply({'channel': CHANNEL, 'content': '  '})['isError'])
            self.assertTrue(bridge.buzz_reply({'channel': CHANNEL, 'content': 'x' * 4001})['isError'])
            self.assertTrue(bridge.buzz_reply({'channel': CHANNEL, 'content': 'x', 'reply_to': 'nothex'})['isError'])
            run.assert_not_called()

    def test_reply_runs_buzz_without_a_shell_and_sends_the_text_on_stdin(self):
        done = mock.Mock(returncode=0, stderr='')
        with mock.patch.object(bridge.subprocess, 'run', return_value=done) as run:
            result = bridge.buzz_reply({'channel': CHANNEL, 'content': '$(ls) `id` ; hello', 'reply_to': 'ab' * 32})
        self.assertFalse(result['isError'])
        command = run.call_args[0][0]
        self.assertEqual(command[:4], ['buzz', 'messages', 'send', '--channel'])
        self.assertIsInstance(command, list)
        self.assertEqual(run.call_args[1]['input'], '$(ls) `id` ; hello')
        self.assertNotIn('shell', run.call_args[1])

    def test_protocol_handshake_and_unknown_methods(self):
        self.assertEqual(bridge.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}})['result']['protocolVersion'], '2025-06-18')
        self.assertIsNone(bridge.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}))
        self.assertEqual(bridge.handle({'jsonrpc': '2.0', 'id': 2, 'method': 'resources/list'})['error']['code'], -32601)


if __name__ == '__main__':
    unittest.main()
