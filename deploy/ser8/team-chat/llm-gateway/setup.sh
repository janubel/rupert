#!/bin/bash
# Runs INSIDE the rupert-llm container: llama.cpp (official Vulkan build, on the Radeon 780M) + the models, checksummed.
# Before it, on the SER8 host: `incus config device add rupert-llm gpu0 gpu gid=<llm gid> mode=0660` (the GPU), and,
# because the container has no internet, the Vulkan driver packages downloaded on the host and installed inside:
#   inside:  apt-get install --print-uris -y --no-install-recommends mesa-vulkan-drivers libvulkan1   (list the .debs)
#   host:    curl each URL, incus file push them in;  inside: dpkg -i *.deb
# Every model in models.json runs with --n-gpu-layers 99. Rollback to CPU: ln -sfn <prism CPU build> /opt/llama/current
# and restore /etc/rupert-llm/models.json.cpu-20261022, then systemctl restart rupert-llm-gateway.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl ca-certificates python3 libgomp1 >/dev/null
useradd --system --home-dir /var/lib/rupert-llm --shell /usr/sbin/nologin llm 2>/dev/null || true
install -d -o llm -g llm /var/lib/rupert-llm /var/lib/rupert-llm/models
install -d /opt/llama
cd /opt/llama
curl -fsSL -o llama.tgz https://github.com/ggml-org/llama.cpp/releases/download/b11819/llama-b11819-bin-ubuntu-vulkan-x64.tar.gz
echo "9b363badcca7cf040dec5f2a8453963b96e01de4e4a59d2fc7cb5989ac21c397  llama.tgz" | sha256sum -c
tar xzf llama.tgz && rm llama.tgz && mv llama-b11819 llama-b11819-vulkan
ln -sfn /opt/llama/llama-b11819-vulkan /opt/llama/current
/opt/llama/current/llama-server --list-devices
fetch() { # repo file sha
  local dest=/var/lib/rupert-llm/models/$2
  [ -f "$dest" ] && echo "$3  $dest" | sha256sum -c --quiet && { echo "have $2"; return; }
  curl -fsSL -o "$dest.part" "https://huggingface.co/$1/resolve/main/$2"
  echo "$3  $dest.part" | sha256sum -c --quiet
  mv "$dest.part" "$dest"; chown llm:llm "$dest"; echo "got $2"
}
fetch LiquidAI/LFM2.5-8B-A1B-GGUF LFM2.5-8B-A1B-Q4_K_M.gguf 4923ec14f06b968b74d663e5949867d2d9c3bf13a20b8be1a9f9af39989b2bb0
fetch google/gemma-4-E4B-it-qat-q4_0-gguf gemma-4-E4B_q4_0-it.gguf 676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee
ls -la /var/lib/rupert-llm/models
