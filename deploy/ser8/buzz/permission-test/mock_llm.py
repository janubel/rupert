#!/usr/bin/env python3
"""Tiny OpenAI-compatible mock model for checking opencode's permission rules without a real model or key.

For each conversation it makes exactly one shell tool call, chosen by a keyword in the user message (see CASES), then
answers "done". Test scaffolding only: it listens on 127.0.0.1 and must never run on a public interface."""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHANNEL = '00000000-0000-0000-0000-000000000000'
SEND = 'buzz messages send --channel %s' % CHANNEL
CASES = {
    'ALLOWED':   SEND + ' --content "pong"',
    'FORBIDDEN': 'ls /root',
    'CHAINED':   SEND + ' --content hi; ls /root',
    'AMP':       SEND + ' --content hi && ls /root',
    'PIPE':      SEND + ' --content hi | cat',
    'NEWLINE':   SEND + ' --content hi\nls /root',
    'SUBST':     SEND + ' --content "$(ls /root)"',
    'BACKTICK':  SEND + ' --content `ls /root`',
    'ENVVAR':    SEND + ' --content "$BUZZ_PRIVATE_KEY"',
    'REDIR':     SEND + ' --content hi > /tmp/permission-test-pwned.txt',
    'STDIN':     SEND + ' --content - < /etc/hostname',
    'QUICK':     'bin/rails runner scripts/quick_reports.rb today',
    'HEREDOC':   "bin/rails runner scripts/feedback_intake.rb file <<'RUPERT_INTAKE_END'\n{\"kind\":\"bug\",\"summary\":\"x\"}\nRUPERT_INTAKE_END",
    'HEREREAD':  "bin/rails runner scripts/feedback_intake.rb file <<'RUPERT_INTAKE_END' < /etc/passwd\n{}\nRUPERT_INTAKE_END",
}

def last_user_text(messages):
    for m in reversed(messages):
        if m.get('role') == 'user':
            c = m.get('content')
            if isinstance(c, list):
                c = ' '.join(p.get('text', '') for p in c if isinstance(p, dict))
            return c or ''
    return ''

def sse(handler, delta, finish=None):
    chunk = {'id': 'chatcmpl-mock', 'object': 'chat.completion.chunk', 'created': int(time.time()),
             'model': 'mock-1', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
    handler.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
    handler.wfile.flush()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps({'data': [{'id': 'mock-1', 'object': 'model'}]}).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        messages = body.get('messages', [])
        tools = [t['function']['name'] for t in body.get('tools', []) if 'function' in t]
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        if messages and messages[-1].get('role') == 'tool':
            sse(self, {'role': 'assistant', 'content': 'done'}); sse(self, {}, 'stop')
        else:
            text = last_user_text(messages)
            tag = next((k for k in CASES if re.search(r'\b%s\b' % k, text)), 'ALLOWED')
            shell = next((t for t in tools if t in ('bash', 'shell')), 'shell')
            args = json.dumps({'command': CASES[tag], 'description': 'permission test'})
            sse(self, {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'call_mock1', 'type': 'function', 'function': {'name': shell, 'arguments': args}}]})
            sse(self, {}, 'tool_calls')
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 8099), Handler).serve_forever()
