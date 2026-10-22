#!/usr/bin/env bash
# Runs Ollama for team chat in its own Incus container on SER8 and pulls the
# local models. Run on the SER8 host as a user in the incus group (no sudo):
#
#   bash deploy/ser8/team-chat/setup-local-model.sh [model ...]
#
# Default models: qwen3.5:4b (recommended: best small-model tool calling) and
# gemma4:e2b (the faster, weaker alternative). The production `rupert`
# container is never touched here; point it at the model afterwards with
# OLLAMA_URL / RUPERT_CHAT_* in /etc/rupert.env (docs/ops/team-chat.md).
set -euo pipefail

NAME="${RUPERT_LLM_CONTAINER:-rupert-llm}"
IMAGE="${RUPERT_LLM_IMAGE:-images:ubuntu/24.04}"
MEMORY="${RUPERT_LLM_MEMORY:-12GiB}"
CPUS="${RUPERT_LLM_CPUS:-6}"
MODELS=("$@")
[ ${#MODELS[@]} -eq 0 ] && MODELS=(qwen3.5:4b gemma4:e2b)

if ! incus info "$NAME" >/dev/null 2>&1; then
  echo "Creating $NAME ($IMAGE, $CPUS CPUs, $MEMORY)…"
  incus launch "$IMAGE" "$NAME" -c limits.memory="$MEMORY" -c limits.cpu="$CPUS" -c boot.autostart=true
  for _ in $(seq 1 30); do incus exec "$NAME" -- true 2>/dev/null && break; sleep 2; done
  incus exec "$NAME" -- sh -c 'until getent hosts ollama.com >/dev/null; do sleep 2; done'
fi

if ! incus exec "$NAME" -- sh -c 'command -v ollama' >/dev/null 2>&1; then
  echo "Installing Ollama (official installer from ollama.com)…"
  incus exec "$NAME" -- sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates zstd >/dev/null'
  incus exec "$NAME" -- sh -c 'curl -fsSL https://ollama.com/install.sh | sh'
fi

# Listen on the container network (reachable from `rupert` as $NAME.incus), keep one model warm.
incus exec "$NAME" -- sh -c 'mkdir -p /etc/systemd/system/ollama.service.d && cat > /etc/systemd/system/ollama.service.d/rupert.conf <<CONF
[Service]
Environment=OLLAMA_HOST=0.0.0.0:11434
Environment=OLLAMA_KEEP_ALIVE=30m
Environment=OLLAMA_NUM_PARALLEL=2
Environment=OLLAMA_CONTEXT_LENGTH=16384
CONF
systemctl daemon-reload && systemctl restart ollama'
incus exec "$NAME" -- sh -c 'for i in $(seq 1 30); do curl -fs http://127.0.0.1:11434/api/version >/dev/null && exit 0; sleep 1; done; exit 1'

for model in "${MODELS[@]}"; do
  echo "Pulling $model…"
  incus exec "$NAME" -- ollama pull "$model"
done

echo
echo "Models:"
incus exec "$NAME" -- ollama list
echo
echo "Quick speed check (${MODELS[0]}):"
incus exec "$NAME" -- sh -c "ollama run --verbose '${MODELS[0]}' 'Reply with one short sentence: what is a stock count?' 2>&1 | grep -E 'eval rate|^[A-Z]' | head -5"
echo
echo "Reachable from rupert as: http://$NAME.incus:11434"
