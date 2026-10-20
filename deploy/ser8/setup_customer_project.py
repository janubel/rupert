#!/usr/bin/env python3
"""Create only dedicated Rupert project/network/profile; refuse existing names.
Run once on SER8 after reviewing the chosen subnet and resource budget.
"""
import json
import subprocess


def run(*args, payload=None):
    return subprocess.run(['incus', *args], input=payload, text=True, capture_output=True, check=True).stdout


def main():
    projects = json.loads(run('project', 'list', '--format=json'))
    networks = json.loads(run('network', 'list', '--format=json'))
    if any(p['name'] == 'rupert-customers' for p in projects) or any(n['name'] == 'rupert-customer-net' for n in networks):
        raise ValueError('Dedicated resources already exist; inspect rather than overwrite')
    run('network', 'acl', 'create', 'rupert-customer-egress')
    private = '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,127.0.0.0/8,224.0.0.0/4'
    # Ingress rejects peer access. DNS/DHCP are the only permitted private-address
    # egress ports; private application, metadata and management ports are denied.
    rules = [
        {'action': 'reject', 'state': 'enabled', 'protocol': 'tcp', 'destination': private, 'destination_port': '0-52,54-65535'},
        {'action': 'reject', 'state': 'enabled', 'protocol': 'udp', 'destination': private, 'destination_port': '0-52,54-66,68-65535'},
        {'action': 'reject', 'state': 'enabled', 'protocol': 'icmp4', 'destination': private},
    ]
    run('network', 'acl', 'edit', 'rupert-customer-egress', payload=json.dumps({'description': 'Customer egress isolation; no private service access', 'ingress': [], 'egress': rules, 'config': {}}))
    run('network', 'create', 'rupert-customer-net', 'ipv4.address=10.218.64.1/24', 'ipv4.nat=true', 'ipv6.address=none',
        'security.acls=rupert-customer-egress', 'security.acls.default.ingress.action=reject', 'security.acls.default.egress.action=allow')
    run('project', 'create', 'rupert-customers', '-c', 'features.images=false', '-c', 'features.profiles=true', '-c', 'features.networks=false',
        '-c', 'restricted=true', '-c', 'restricted.containers.privilege=isolated', '-c', 'restricted.containers.nesting=block',
        '-c', 'restricted.devices.disk=block', '-c', 'restricted.devices.proxy=allow', '-c', 'restricted.devices.nic=managed',
        '-c', 'restricted.networks.access=rupert-customer-net', '-c', 'limits.containers=8', '-c', 'limits.memory=8GiB')
    run('profile', 'create', 'rupert-customer', '--project', 'rupert-customers')
    profile = {'description': 'No host mounts, no nesting, isolated UID ranges, private root filesystem',
        'config': {'security.privileged': 'false', 'security.nesting': 'false', 'security.idmap.isolated': 'true', 'limits.cpu': '1', 'limits.memory': '1GiB'},
        'devices': {'root': {'type': 'disk', 'pool': 'default', 'path': '/'},
                    'eth0': {'type': 'nic', 'network': 'rupert-customer-net', 'name': 'eth0', 'security.mac_filtering': 'true', 'security.ipv4_filtering': 'true'}}}
    run('profile', 'edit', 'rupert-customer', '--project', 'rupert-customers', payload=json.dumps(profile))
    print('Dedicated customer project, network ACL and profile created. No instances or public routes were created.')


if __name__ == '__main__':
    main()
