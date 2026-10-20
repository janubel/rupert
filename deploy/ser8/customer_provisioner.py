#!/usr/bin/env python3
"""Host-only Incus worker. No instance socket or host credential enters Rails.
Run from a root-owned service environment; only sanitized state codes are logged.
"""
import json
import ipaddress
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
PROJECT = "rupert-customers"
ACL = "rupert-customer-egress"
PROFILE = "rupert-customer"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def secure_open(request, timeout):
    # urllib otherwise forwards Authorization across some redirects.
    return urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout)


class ProvisionError(Exception):
    def __init__(self, code):
        self.code = code


def command(args, payload=None, timeout=180):
    result = subprocess.run(args, input=payload, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise ProvisionError("bootstrap_failed")
    return result.stdout


class Worker:
    def __init__(self, env=None, run=command):
        self.env = dict(os.environ if env is None else env)
        self.run = run
        self.origin = self.env.get("RUPERT_CONTROL_PLANE_ORIGIN", "")
        parsed = urlsplit(self.origin)
        if parsed.scheme != "https" or parsed.path or parsed.query or parsed.fragment or parsed.username:
            raise ValueError("A canonical HTTPS control origin is required")
        self.token = self.env.get("RUPERT_PROVISIONER_TOKEN", "")
        if len(self.token) < 32:
            raise ValueError("A private provisioner token is required")
        self.image = self.env.get("RUPERT_CUSTOMER_IMAGE", "")
        self.revision = self.env.get("RUPERT_CUSTOMER_REVISION", "")
        if not re.fullmatch(r"[0-9a-f]{64}", self.image) or not re.fullmatch(r"[0-9a-f]{40}", self.revision):
            raise ValueError("A reviewed clean image fingerprint and exact revision are required")
        self.domain = self.env.get("RUPERT_WORKSPACE_BASE_DOMAIN", "workspaces.rupertpos.com")
        if not re.fullmatch(r"(?:[a-z0-9-]+\.)+[a-z]{2,63}", self.domain):
            raise ValueError("Invalid workspace base domain")
        self.quota = int(self.env.get("RUPERT_CUSTOMER_MAX_INSTANCES", "8"))
        if not 1 <= self.quota <= 50:
            raise ValueError("The pilot quota must be 1–50 instances")
        self.router = self.env.get("RUPERT_CUSTOMER_ROUTE_COMMAND", "/usr/local/libexec/rupert-customer-route")
        if not self.router.startswith("/"):
            raise ValueError("The router must be an operator-installed absolute executable")

    def api(self, path, fields):
        request = urllib.request.Request(self.origin + path, data=json.dumps(fields).encode(), method="POST",
            headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        with secure_open(request, timeout=15) as response:
            return None if response.status == 204 else json.load(response) if response.headers.get("Content-Type", "").startswith("application/json") else {}

    def validate(self, job):
        if type(job.get("id")) is not int or not 0 < job["id"] < 1000:
            raise ProvisionError("create_failed")
        if not UUID.fullmatch(job.get("instance_id", "")):
            raise ProvisionError("create_failed")
        if job.get("instance_name") != "rupert-customer-" + job["instance_id"]:
            raise ProvisionError("create_failed")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,61}[a-z0-9]\." + re.escape(self.domain), job.get("hostname", "")):
            raise ProvisionError("routing_failed")
        if not re.fullmatch(r"[a-z0-9-]{2,63}", job.get("subdomain", "")):
            raise ProvisionError("create_failed")
        if type(job.get("port")) is not int or job["port"] != 24000 + job["id"]:
            raise ProvisionError("create_failed")
        if not re.fullmatch(r"[0-9a-f]{64}", job.get("instance_secret", "")):
            raise ProvisionError("bootstrap_failed")
        if not UUID.fullmatch(job.get("tenant_id", "")) or not job.get("google_subject"):
            raise ProvisionError("bootstrap_failed")

    def incus(self, *args, payload=None, timeout=180):
        return self.run(["incus", *args], payload=payload, timeout=timeout)

    def network_name(self, job):
        return "rpc-" + job["instance_id"].replace("-", "")[:10]

    def network_address(self, job):
        return str(ipaddress.ip_network("10.216.0.0/14")[job["id"] * 256 + 1]) + "/24"

    def ensure_network(self, job):
        name = self.network_name(job)
        networks = json.loads(self.incus("network", "list", "--format=json", "--project", "default"))
        if not any(row["name"] == name for row in networks):
            self.incus("network", "create", name, "--type", "bridge", "--project", "default",
                "ipv4.address=" + self.network_address(job), "ipv4.nat=true", "ipv6.address=none",
                "security.acls=" + ACL, "security.acls.default.ingress.action=reject", "security.acls.default.egress.action=allow",
                "user.rupert.workspace_id=" + job["instance_id"])
        network = json.loads(self.incus("query", "/1.0/networks/" + name))
        config = network.get("config", {})
        if config.get("user.rupert.workspace_id") != job["instance_id"] or config.get("security.acls") != ACL or config.get("ipv4.address") != self.network_address(job) or config.get("ipv6.address") != "none" or config.get("ipv4.nat") != "true" or config.get("security.acls.default.ingress.action") != "reject" or config.get("security.acls.default.egress.action") != "allow":
            raise ProvisionError("create_failed")
        peers = [url for url in network.get("used_by", []) if "/instances/" in url]
        if any("/1.0/instances/" + job["instance_name"] + "?project=" + PROJECT != url for url in peers):
            raise ProvisionError("create_failed")
        project = json.loads(self.incus("query", "/1.0/projects/" + PROJECT))
        allowed = project.get("config", {}).get("restricted.networks.access", "").split(",")
        if name not in allowed:
            allowed = [entry for entry in allowed if entry]
            if any(entry != "rupert-cust0" and not re.fullmatch(r"rpc-[0-9a-f]{10}", entry) for entry in allowed):
                raise ProvisionError("create_failed")
            self.incus("project", "set", PROJECT, "restricted.networks.access=" + ",".join(allowed + [name]))
        return name

    def verify_policy(self, instance, job):
        config = instance.get("expanded_config", {})
        if config.get("security.privileged", "false") != "false" or config.get("security.nesting", "false") != "false" or config.get("security.idmap.isolated") != "true":
            raise ProvisionError("create_failed")
        devices = instance.get("expanded_devices", {})
        if set(devices) - {"eth0", "root", "web"}:
            raise ProvisionError("create_failed")
        root = devices.get("root", {})
        if root.get("type") != "disk" or root.get("path") != "/" or root.get("source"):
            raise ProvisionError("create_failed")
        nic = devices.get("eth0", {})
        if nic.get("type") != "nic" or nic.get("network") != self.network_name(job) or nic.get("security.mac_filtering") != "true" or nic.get("security.ipv4_filtering") != "true":
            raise ProvisionError("create_failed")

    def progress(self, job, phase, failure_code=None):
        fields = {"lease": job["lease"], "phase": phase}
        if failure_code:
            fields["failure_code"] = failure_code
        self.api("/internal/workspaces/" + str(job["id"]) + "/progress", fields)

    def provision(self, job):
        self.validate(job)
        image = json.loads(self.incus("query", "/1.0/images/" + self.image))
        properties = image.get("properties", {})
        if properties.get("user.rupert.clean_template") != "true" or properties.get("user.rupert.revision") != self.revision:
            raise ProvisionError("image_unavailable")
        instances = json.loads(self.incus("list", "--project", PROJECT, "--format=json"))
        existing = next((row for row in instances if row["name"] == job["instance_name"]), None)
        if existing is None and len(instances) >= self.quota:
            raise ProvisionError("quota_exceeded")
        network = self.ensure_network(job)
        if existing is None:
            self.incus("init", self.image, job["instance_name"], "--project", PROJECT, "--profile", PROFILE,
                "-c", "security.privileged=false", "-c", "security.nesting=false", "-c", "security.idmap.isolated=true",
                "-c", "limits.cpu=1", "-c", "limits.memory=1GiB", "-c", "limits.processes=256", "-c", "boot.autostart=true",
                "-c", "user.rupert.workspace_id=" + job["instance_id"])
        instance = json.loads(self.incus("query", "/1.0/instances/" + job["instance_name"] + "?project=" + PROJECT))
        if instance.get("config", {}).get("user.rupert.workspace_id") != job["instance_id"]:
            raise ProvisionError("create_failed")
        if "eth0" not in instance.get("expanded_devices", {}):
            self.incus("config", "device", "add", job["instance_name"], "eth0", "nic", "--project", PROJECT,
                "network=" + network, "name=eth0", "security.mac_filtering=true", "security.ipv4_filtering=true")
            instance = json.loads(self.incus("query", "/1.0/instances/" + job["instance_name"] + "?project=" + PROJECT))
        self.verify_policy(instance, job)
        web = instance.get("expanded_devices", {}).get("web")
        if web and (web.get("type") != "proxy" or web.get("listen") != "tcp:127.0.0.1:" + str(job["port"]) or web.get("connect") != "tcp:127.0.0.1:3000"):
            raise ProvisionError("create_failed")
        if instance.get("status") != "Running":
            self.incus("start", job["instance_name"], "--project", PROJECT)
        self.progress(job, "bootstrapping")
        data = dict(job, control_origin=self.origin, revision=self.revision)
        # The image supplies this reviewed bootstrap program; no customer shell text.
        self.incus("exec", job["instance_name"], "--project", PROJECT, "--", "/usr/local/libexec/rupert-customer-bootstrap",
            payload=json.dumps(data), timeout=600)
        self.progress(job, "checking")
        if "web" not in instance.get("expanded_devices", {}):
            self.incus("config", "device", "add", job["instance_name"], "web", "proxy", "--project", PROJECT,
                "listen=tcp:127.0.0.1:" + str(job["port"]), "connect=tcp:127.0.0.1:3000")
        self.check_health(job, public=False)
        self.progress(job, "routing")
        self.run([self.router, job["hostname"], str(job["port"])], timeout=120)
        self.check_health(job, public=True)
        self.progress(job, "complete")

    def check_health(self, job, public):
        url = ("https://" + job["hostname"] if public else "http://127.0.0.1:" + str(job["port"])) + "/instance/health"
        headers = {"Authorization": "Bearer " + job["instance_secret"], "Host": job["hostname"]}
        if not public:
            headers["X-Forwarded-Proto"] = "https"
        for _ in range(30):
            try:
                with secure_open(urllib.request.Request(url, headers=headers), timeout=5) as response:
                    body = json.load(response)
                if body.get("ready") is True and body.get("instance_id") == job["instance_id"] and body.get("tenant_id") == job["tenant_id"] and body.get("revision") == self.revision:
                    return
            except (OSError, ValueError, urllib.error.HTTPError):
                pass
            time.sleep(2)
        raise ProvisionError("health_failed" if not public else "routing_failed")

    def once(self):
        job = self.api("/internal/workspaces/claim", {})
        if not job:
            return False
        try:
            self.provision(job)
        except (ProvisionError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
            code = error.code if isinstance(error, ProvisionError) else "bootstrap_failed"
            self.progress(job, "failed", code)
            print("Customer instance setup stopped:", code, flush=True)
        return True


def main():
    worker = Worker()
    if "--once" in sys.argv:
        worker.once()
    else:
        while True:
            try:
                worker.once()
            except (OSError, ValueError, urllib.error.HTTPError):
                print("Provisioning control plane unavailable; retrying.", flush=True)
            time.sleep(15)


if __name__ == "__main__":
    main()
