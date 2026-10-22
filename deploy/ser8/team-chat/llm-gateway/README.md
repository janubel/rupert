# rupert-llm: local models for Team chat's @agents

Runs in its own Incus container on SER8 (`rupert-llm`, 10.96.131.7), never inside `rupert`. See docs/ops/team-chat.md.

```bash
incus launch images:ubuntu/24.04 rupert-llm -c limits.cpu=8 -c limits.memory=14GiB -c boot.autostart=true -c security.idmap.isolated=true
incus config device override rupert-llm eth0 ipv4.address=10.96.131.7 && incus restart rupert-llm
# llama.cpp (PrismML fork, CPU) + the three models, all sha256-checked:
incus file push setup.sh rupert-llm/root/setup.sh && incus exec rupert-llm -- bash /root/setup.sh
incus exec rupert-llm -- ln -sfn /opt/llama/llama-prism-b10787-73bfe6c /opt/llama/current
incus file push llm_gateway.py rupert-llm/usr/local/lib/rupert-llm/llm_gateway.py --create-dirs
incus file push models.json rupert-llm/etc/rupert-llm/models.json --create-dirs
incus file push rupert-llm-gateway.service rupert-llm/etc/systemd/system/
incus exec rupert-llm -- systemctl enable --now rupert-llm-gateway
incus exec rupert-llm -- curl -s 127.0.0.1:8080/health
```

Adding a model: put its GGUF in `/var/lib/rupert-llm/models/`, add it to `models.json`, restart the gateway, and add
an entry to `TeamChat::LocalAgents::ALL` (handle, name, model id).
