#!/usr/bin/env python3
"""One-model-at-a-time gateway for Team chat's local @agents (rupert-llm container on SER8).

Serves an OpenAI-compatible API (GET /v1/models, POST /v1/chat/completions, streaming or not) in front of
llama.cpp's llama-server. Only ONE model is ever loaded: a request for another model waits for the request in
flight, stops the running llama-server and starts the requested one. Requests are handled one at a time.
A model with no request for IDLE_SECONDS (default 300) is unloaded, so nothing sits in memory between chats.

Models come from models.json: {"id": {"file": "/path/model.gguf", "ctx": 16384, "args": [...]}}.
Only the clients in --allow may call it. Python standard library only.
"""
import argparse
import http.client
import json
import re
import logging
import os
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger('llm_gateway')


class Engine:
    """Owns the single llama-server process."""

    def __init__(self, models, server_bin, port, threads, idle_seconds, start_timeout):
        self.models = models
        self.server_bin = server_bin
        self.port = port
        self.threads = threads
        self.idle_seconds = idle_seconds
        self.start_timeout = start_timeout
        self.lock = threading.Lock()  # one request (and so one model) at a time
        self.proc = None
        self.current = None
        self.last_used = time.monotonic()

    def status(self):
        return {'loaded': self.current, 'idle_seconds': round(time.monotonic() - self.last_used), 'busy': self.lock.locked()}

    def ensure(self, model_id):
        """Load model_id, unloading any other model first. Caller holds self.lock."""
        if self.current == model_id and self.proc and self.proc.poll() is None:
            return
        self.stop()
        spec = self.models[model_id]
        cmd = [self.server_bin, '--model', spec['file'], '--host', '127.0.0.1', '--port', str(self.port),
               '--ctx-size', str(spec.get('ctx', 16384)), '--threads', str(self.threads), '--jinja',
               '--parallel', '1', '--no-webui'] + list(spec.get('args', []))
        log.info('loading %s', model_id)
        started = time.monotonic()
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.current = model_id
        while time.monotonic() - started < self.start_timeout:
            if self.proc.poll() is not None:
                self.current = None
                raise RuntimeError('llama-server exited while loading %s' % model_id)
            try:
                conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
                conn.request('GET', '/health')
                ready = conn.getresponse().status == 200
                conn.close()
                if ready:
                    log.info('loaded %s in %.1fs', model_id, time.monotonic() - started)
                    return
            except OSError:
                pass
            time.sleep(0.5)
        self.stop()
        raise RuntimeError('timed out loading %s' % model_id)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            log.info('unloading %s', self.current)
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait()
        self.proc = None
        self.current = None

    def reap_idle(self):
        while True:
            time.sleep(15)
            if self.current is None:
                continue
            if self.lock.acquire(blocking=False):
                try:
                    if self.current and time.monotonic() - self.last_used > self.idle_seconds:
                        log.info('idle for %ss', self.idle_seconds)
                        self.stop()
                finally:
                    self.lock.release()


def log_timings(model_id, tail, seconds):
    """One line per request: prompt tokens read fresh vs reused from the cache, and speeds (llama-server 'timings')."""
    match = None
    for match in re.finditer(rb'"timings"\s*:\s*(\{[^{}]*\})', tail):
        pass
    if not match:
        log.info('request model=%s seconds=%.1f (no timings)', model_id, seconds)
        return
    try:
        t = json.loads(match.group(1))
    except ValueError:
        return
    log.info('request model=%s seconds=%.1f prompt_new=%s prompt_cached=%s prompt_ms=%.0f prompt_tps=%.0f gen=%s gen_tps=%.1f',
             model_id, seconds, t.get('prompt_n'), t.get('cache_n'), t.get('prompt_ms', 0), t.get('prompt_per_second', 0),
             t.get('predicted_n'), t.get('predicted_per_second', 0))


def make_handler(engine, allow):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.0'  # streamed bodies end when the connection closes

        def log_message(self, fmt, *args):
            log.debug(fmt, *args)

        def allowed(self):
            if self.client_address[0] in allow:
                return True
            self.reply(403, {'error': {'message': 'not allowed'}})
            return False

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.allowed():
                return
            if self.path.rstrip('/') in ('/v1/models', '/models'):
                self.reply(200, {'object': 'list', 'data': [{'id': mid, 'object': 'model', 'owned_by': 'rupert-llm'} for mid in engine.models]})
            elif self.path.rstrip('/') in ('/health', '/v1/health'):
                self.reply(200, engine.status())
            else:
                self.reply(404, {'error': {'message': 'not found'}})

        def do_POST(self):
            if not self.allowed():
                return
            if self.path.rstrip('/') not in ('/v1/chat/completions', '/chat/completions'):
                return self.reply(404, {'error': {'message': 'not found'}})
            try:
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            except ValueError:
                return self.reply(400, {'error': {'message': 'bad json'}})
            model_id = body.get('model')
            if model_id not in engine.models:
                return self.reply(404, {'error': {'message': 'unknown model %s' % model_id}})
            with engine.lock:
                engine.last_used = time.monotonic()
                try:
                    engine.ensure(model_id)
                except RuntimeError as error:
                    log.warning('%s', error)
                    return self.reply(503, {'error': {'message': str(error)}})
                try:
                    self.forward(body)
                finally:
                    engine.last_used = time.monotonic()

        def forward(self, body):
            conn = http.client.HTTPConnection('127.0.0.1', engine.port, timeout=600)
            data = json.dumps(body).encode()
            conn.request('POST', '/v1/chat/completions', body=data, headers={'Content-Type': 'application/json'})
            upstream = conn.getresponse()
            self.send_response(upstream.status)
            self.send_header('Content-Type', upstream.getheader('Content-Type', 'application/json'))
            self.end_headers()
            started = time.monotonic()
            tail = b''
            while True:
                chunk = upstream.read1(65536) if hasattr(upstream, 'read1') else upstream.read(65536)
                if not chunk:
                    break
                tail = (tail + chunk)[-32768:]
                self.wfile.write(chunk)
                self.wfile.flush()
            conn.close()
            log_timings(body.get('model'), tail, time.monotonic() - started)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--models', default='/etc/rupert-llm/models.json')
    parser.add_argument('--listen', default='0.0.0.0:8080')
    parser.add_argument('--allow', action='append', default=['127.0.0.1'])
    parser.add_argument('--server-bin', default='/opt/llama/llama-server')
    parser.add_argument('--server-port', type=int, default=8081)
    parser.add_argument('--threads', type=int, default=8)
    parser.add_argument('--idle-seconds', type=int, default=300)
    parser.add_argument('--start-timeout', type=int, default=240)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    models = json.load(open(args.models))
    engine = Engine(models, args.server_bin, args.server_port, args.threads, args.idle_seconds, args.start_timeout)
    threading.Thread(target=engine.reap_idle, daemon=True).start()
    host, port = args.listen.rsplit(':', 1)
    server = ThreadingHTTPServer((host, int(port)), make_handler(engine, set(args.allow)))
    log.info('listening on %s for %s; models: %s', args.listen, sorted(set(args.allow)), ', '.join(models))
    try:
        server.serve_forever()
    finally:
        engine.stop()


if __name__ == '__main__':
    main()
