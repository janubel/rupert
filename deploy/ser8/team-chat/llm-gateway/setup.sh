#!/bin/bash
# Runs INSIDE the rupert-llm container: llama.cpp (PrismML fork, CPU build) + the three models, checksummed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl ca-certificates python3 libgomp1 >/dev/null
useradd --system --home-dir /var/lib/rupert-llm --shell /usr/sbin/nologin llm 2>/dev/null || true
install -d -o llm -g llm /var/lib/rupert-llm /var/lib/rupert-llm/models
install -d /opt/llama
cd /opt/llama
curl -fsSL -o llama.tgz https://github.com/PrismML-Eng/llama.cpp/releases/download/prism-b10787-73bfe6c/llama-prism-b10787-73bfe6c-bin-ubuntu-x64.tar.gz
echo "bff69881bdb2b09dcbf5e99a1cb532b2a6821c6dc42d33ac53b2fa2cd3e6f214  llama.tgz" | sha256sum -c
tar xzf llama.tgz && rm llama.tgz
find /opt/llama -name llama-server -type f | head -1
fetch() { # repo file sha
  local dest=/var/lib/rupert-llm/models/$2
  [ -f "$dest" ] && echo "$3  $dest" | sha256sum -c --quiet && { echo "have $2"; return; }
  curl -fsSL -o "$dest.part" "https://huggingface.co/$1/resolve/main/$2"
  echo "$3  $dest.part" | sha256sum -c --quiet
  mv "$dest.part" "$dest"; chown llm:llm "$dest"; echo "got $2"
}
fetch prism-ml/Ternary-Bonsai-2-9B-gguf Ternary-Bonsai-2-9B-PQ2_0.gguf 7a89ab48f5038c704480f60781f9b8d4035351f5f6beb7d11fad80001fde23f9
fetch LiquidAI/LFM2.5-8B-A1B-GGUF LFM2.5-8B-A1B-Q4_K_M.gguf 4923ec14f06b968b74d663e5949867d2d9c3bf13a20b8be1a9f9af39989b2bb0
fetch google/gemma-4-E4B-it-qat-q4_0-gguf gemma-4-E4B_q4_0-it.gguf 676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee
ls -la /var/lib/rupert-llm/models
