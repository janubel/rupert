#!/usr/bin/env python3
"""HTTPS CONNECT proxy with a host allow-list, for the sandboxed @rupert agent container.

The agent container may only open TCP to the public front (relay and Rupert) and to this proxy (Incus network ACL).
This proxy lets it reach the model provider and nothing else: CONNECT to port 443 of an allowed host name, only from
the agent's address. It never sees plaintext (TLS is end to end). Standard library only.
  egress_proxy.py --listen 10.96.131.4:3128 --client 10.96.131.6 --allow opencode.ai --allow models.dev
"""
import argparse
import asyncio
import logging

log = logging.getLogger('egress_proxy')


def allowed(host, rules):
    host = host.lower().rstrip('.')
    return any(host == rule or host.endswith('.' + rule) for rule in rules)


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(reader, writer, client_ip, rules):
    peer = writer.get_extra_info('peername')[0]
    try:
        if peer != client_ip:
            log.warning('refused %s: not the agent', peer)
            return
        head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
        first = head.split(b'\r\n', 1)[0].decode('latin-1').split()
        if len(first) < 2 or first[0] != 'CONNECT':
            writer.write(b'HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n')
            return
        host, _, port = first[1].rpartition(':')
        if port != '443' or not allowed(host, rules):
            log.warning('denied CONNECT %s', first[1][:100])
            writer.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
            return
        upstream_reader, upstream_writer = await asyncio.wait_for(asyncio.open_connection(host, 443), 10)
        log.info('CONNECT %s', host)
        writer.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
        await writer.drain()
        await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))
    except Exception as error:
        log.info('closed: %s', type(error).__name__)
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--listen', required=True)
    parser.add_argument('--client', required=True)
    parser.add_argument('--allow', action='append', required=True)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    host, port = args.listen.rsplit(':', 1)
    rules = [rule.lower() for rule in args.allow]
    server = await asyncio.start_server(lambda r, w: handle(r, w, args.client, rules), host, int(port))
    log.info('listening on %s, allowing %s for %s', args.listen, rules, args.client)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
