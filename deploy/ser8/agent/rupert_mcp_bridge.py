#!/usr/bin/env python3
"""MCP server (stdio) that is the @rupert agent's ONLY tool set.

buzz-acp starts it (BUZZ_ACP_MCP_COMMAND) and hands it to opencode, whose shell, file and web tools are all denied.
It offers exactly:
  * buzz_reply        post a message to a Buzz channel (runs `buzz messages send` with an argument list, no shell)
  * a fixed allow-list of Rupert's MCP tools, forwarded over HTTPS with a scoped bearer token (RUPERT_MCP_URL,
    RUPERT_MCP_TOKEN). Anything else the model asks for is refused here, whatever the token would permit.
The Buzz key reaches this process from buzz-acp (BUZZ_PRIVATE_KEY, BUZZ_RELAY_URL); the Rupert token comes from the
environment file only the service user can read. Python 3 standard library only, no Rails, no Rupert files.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ALLOWED_RUPERT_TOOLS = (
    'get_workspace_info', 'list_reports', 'sales_summary', 'sales_tax_report', 'inventory_search',
    'stock_comparison', 'swipesimple_items', 'list_tasks', 'list_alerts', 'submit_feedback', 'list_my_feedback',
)
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
HEX64 = re.compile(r'^[0-9a-f]{64}$')
MAX_REPLY = 4000
UPSTREAM_TIMEOUT = 30

REPLY_TOOL = {
    'name': 'buzz_reply',
    'description': 'Post your reply into the Buzz channel. Use the channel UUID and, for a reply inside a thread, the '
                   'event id, both from the [Context] block. A short reply is still a reply: post it. Post nothing '
                   'when you decide not to speak.',
    'inputSchema': {
        'type': 'object',
        'properties': {
            'channel': {'type': 'string', 'description': 'Channel UUID from [Context].'},
            'content': {'type': 'string', 'maxLength': MAX_REPLY, 'description': 'The message text (Markdown).'},
            'reply_to': {'type': 'string', 'description': 'Optional 64-hex event id to reply to.'},
        },
        'required': ['channel', 'content'],
        'additionalProperties': False,
    },
}


def log(*parts):
    print('[rupert_mcp_bridge]', *parts, file=sys.stderr, flush=True)


def rupert_call(payload):
    """POST one JSON-RPC request to Rupert's MCP endpoint; returns the parsed response or raises."""
    url = os.environ.get('RUPERT_MCP_URL', '')
    token = os.environ.get('RUPERT_MCP_TOKEN', '')
    if not url.startswith('https://') or not token:
        raise RuntimeError('Rupert is not configured for this agent (RUPERT_MCP_URL / RUPERT_MCP_TOKEN)')
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(), method='POST',
        headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT) as response:
        return json.loads(response.read().decode())


def list_tools():
    tools = [REPLY_TOOL]
    try:
        upstream = rupert_call({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})
        for tool in upstream.get('result', {}).get('tools', []):
            if tool.get('name') in ALLOWED_RUPERT_TOOLS:
                tools.append(tool)
    except Exception as error:  # the reply tool must keep working when Rupert is unreachable
        log('could not list Rupert tools:', type(error).__name__)
    return tools


def text_result(text, error=False):
    return {'content': [{'type': 'text', 'text': text}], 'isError': error}


def buzz_reply(arguments):
    channel = str(arguments.get('channel', ''))
    content = str(arguments.get('content', ''))
    reply_to = arguments.get('reply_to')
    if not UUID.match(channel):
        return text_result('channel must be the channel UUID from [Context].', True)
    if not content.strip() or len(content) > MAX_REPLY:
        return text_result('content must be 1 to %d characters.' % MAX_REPLY, True)
    command = ['buzz', 'messages', 'send', '--channel', channel, '--content', '-']
    if reply_to:
        if not HEX64.match(str(reply_to)):
            return text_result('reply_to must be a 64-hex event id.', True)
        command += ['--reply-to', str(reply_to)]
    try:
        done = subprocess.run(command, input=content, text=True, capture_output=True, timeout=30)
    except Exception as error:
        return text_result('could not run buzz: %s' % type(error).__name__, True)
    if done.returncode != 0:
        return text_result('buzz failed (%d): %s' % (done.returncode, done.stderr.strip()[:300]), True)
    return text_result('posted')


def call_tool(name, arguments):
    if name == 'buzz_reply':
        return buzz_reply(arguments or {})
    if name not in ALLOWED_RUPERT_TOOLS:
        return text_result('Tool %s is not available to this agent.' % name, True)
    try:
        upstream = rupert_call({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                'params': {'name': name, 'arguments': arguments or {}}})
    except urllib.error.HTTPError as error:
        return text_result('Rupert refused the request (HTTP %d).' % error.code, True)
    except Exception as error:
        return text_result('Rupert could not be reached (%s).' % type(error).__name__, True)
    if 'error' in upstream:
        return text_result('Rupert error: %s' % str(upstream['error'].get('message', ''))[:300], True)
    return upstream.get('result', text_result('empty answer', True))


def handle(message):
    method = message.get('method')
    request_id = message.get('id')
    if method == 'initialize':
        version = (message.get('params') or {}).get('protocolVersion', '2025-06-18')
        result = {'protocolVersion': version, 'capabilities': {'tools': {}},
                  'serverInfo': {'name': 'rupert', 'version': '1'}}
    elif method == 'ping':
        result = {}
    elif method == 'tools/list':
        result = {'tools': list_tools()}
    elif method == 'tools/call':
        params = message.get('params') or {}
        result = call_tool(params.get('name'), params.get('arguments'))
    elif request_id is None:
        return None  # notification (for example notifications/initialized)
    else:
        return {'jsonrpc': '2.0', 'id': request_id, 'error': {'code': -32601, 'message': 'method not found'}}
    return {'jsonrpc': '2.0', 'id': request_id, 'result': result}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + '\n')
            sys.stdout.flush()


if __name__ == '__main__':
    main()
