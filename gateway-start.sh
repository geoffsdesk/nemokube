#!/usr/bin/env bash
# ============================================================================
# NemoKube Gateway — Cloud Run Entrypoint  [WORK IN PROGRESS]
# Two-phase config patch:
#   Phase 1 (BEFORE gateway start): security/auth settings so they're read at boot
#   Phase 2 (AFTER plugin init):    model/NIM settings + print token
# ============================================================================

echo "[nemokube-cloudrun] Starting NemoClaw setup..."
mkdir -p ~/.openclaw

# Run nemoclaw-start for side effects (plugins, auth tokens, config creation).
/usr/local/bin/nemoclaw-start &
SETUP_PID=$!
wait $SETUP_PID 2>/dev/null || true

# Wait for the config file to appear
for i in $(seq 1 30); do
  [ -f ~/.openclaw/openclaw.json ] && break
  sleep 1
done

# ── Kill EVERYTHING nemoclaw-start spawned ──────────────────────────────────
echo "[nemokube-cloudrun] Killing all backgrounded processes..."
MY_PID=$$
for piddir in /proc/[0-9]*; do
  pid=$(basename "$piddir")
  [ "$pid" = "1" ] && continue
  [ "$pid" = "$MY_PID" ] && continue
  kill -9 "$pid" 2>/dev/null || true
done
sleep 2

# Remove any stale lock files
find ~/.openclaw -name "*.lock" -delete 2>/dev/null || true
rm -f ~/.openclaw/.gateway.pid 2>/dev/null || true

# ── PHASE 1: Patch security settings BEFORE gateway starts ─────────────────
# dangerouslyDisableDeviceAuth and allowInsecureAuth are only read at boot,
# so they MUST be in the config before `openclaw gateway run`.
echo "[nemokube-cloudrun] Phase 1: Patching security settings..."
python3 << 'PYEOF'
import json, os

path = os.path.expanduser("~/.openclaw/openclaw.json")
cfg = json.load(open(path))

gateway = cfg.setdefault("gateway", {})
ctrl = gateway.setdefault("controlUi", {})
ctrl["allowedOrigins"] = ["*"]
ctrl["allowInsecureAuth"] = True
ctrl["dangerouslyDisableDeviceAuth"] = True

json.dump(cfg, open(path, "w"), indent=2)
print("[nemokube-cloudrun] Security settings patched (allowInsecureAuth, dangerouslyDisableDeviceAuth, allowedOrigins=*)")
PYEOF

# ── Start gateway fresh ─────────────────────────────────────────────────────
echo "[nemokube-cloudrun] Starting gateway on 127.0.0.1:18789..."
openclaw gateway run &
GATEWAY_PID=$!

# Wait for gateway to be ready
echo "[nemokube-cloudrun] Waiting for gateway to be ready..."
for i in $(seq 1 60); do
  if node -e "const n=require('net');const c=n.connect(18789,'127.0.0.1',()=>{c.destroy();process.exit(0)});c.on('error',()=>process.exit(1))" 2>/dev/null; then
    echo "[nemokube-cloudrun] Gateway is listening."
    break
  fi
  sleep 1
done

# ── Wait for NemoClaw plugin to load and trigger its restart ────────────────
# The NemoClaw plugin takes ~30s to register and triggers a full gateway
# restart (new PID). We MUST wait for this before patching model config or
# starting the proxy.
echo "[nemokube-cloudrun] Waiting 45s for NemoClaw plugin to load..."
sleep 45

# Make sure gateway is listening after any plugin-triggered restart
for i in $(seq 1 30); do
  if node -e "const n=require('net');const c=n.connect(18789,'127.0.0.1',()=>{c.destroy();process.exit(0)});c.on('error',()=>process.exit(1))" 2>/dev/null; then
    echo "[nemokube-cloudrun] Gateway ready after plugin init."
    break
  fi
  sleep 1
done

# ── PHASE 2: Patch model/NIM settings AFTER plugins have stabilized ────────
echo "[nemokube-cloudrun] Phase 2: Patching model and NIM config..."
python3 << 'PYEOF'
import json, os

path = os.path.expanduser("~/.openclaw/openclaw.json")
cfg = json.load(open(path))

model = os.environ.get("INFERENCE_MODEL", "meta/llama-3.1-8b-instruct")
nim_endpoint = os.environ.get("NIM_ENDPOINT", "")
api_key = os.environ.get("NVIDIA_API_KEY", "")

# Fix the model
agents = cfg.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
model_cfg = defaults.setdefault("model", {})
model_cfg["primary"] = model

if "model" in cfg:
    cfg["model"]["primary"] = model

# Set up NIM provider
nim = cfg.setdefault("models", {}).setdefault("providers", {}).setdefault("nim-local", {})
nim["baseUrl"] = nim_endpoint
nim["apiKey"] = api_key
nim["api"] = "openai-completions"
short = model.split("/")[-1]
nim["models"] = [{
    "id": short,
    "name": model,
    "reasoning": False,
    "input": ["text"],
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    "contextWindow": 131072,
    "maxTokens": 8192
}]

# Re-assert security settings in case plugin overwrote them
gateway = cfg.setdefault("gateway", {})
ctrl = gateway.setdefault("controlUi", {})
ctrl["allowedOrigins"] = ["*"]
ctrl["allowInsecureAuth"] = True
ctrl["dangerouslyDisableDeviceAuth"] = True

json.dump(cfg, open(path, "w"), indent=2)
print(f"[nemokube-cloudrun] Config patched: model={model}, endpoint={nim_endpoint}")

# Print the auth token so users can find it in logs
token = cfg.get("gateway", {}).get("auth", {}).get("token", "")
if token:
    print(f"[nemokube-cloudrun] Auth token: {token}")
    chat = os.environ.get("CHAT_UI_URL", "")
    print(f"[nemokube-cloudrun] Access URL: {chat}/#token={token}")
else:
    print("[nemokube-cloudrun] WARNING: No auth token found in config")
PYEOF

# ── Wait for gateway to stabilize after Phase 2 patch ────────────────────
echo "[nemokube-cloudrun] Waiting for gateway to stabilize after config patch..."
sleep 5
for i in $(seq 1 30); do
  if node -e "const n=require('net');const c=n.connect(18789,'127.0.0.1',()=>{c.destroy();process.exit(0)});c.on('error',()=>process.exit(1))" 2>/dev/null; then
    echo "[nemokube-cloudrun] Gateway stable and listening."
    break
  fi
  sleep 1
done

# ── Start reverse proxy ─────────────────────────────────────────────────────
echo "[nemokube-cloudrun] Starting HTTP+WS proxy on 0.0.0.0:8080 -> 127.0.0.1:18789..."
exec node -e "
const http = require('http');
const net = require('net');

const UP_HOST = '127.0.0.1';
const UP_PORT = 18789;

// HTTP requests: proxy normally
const server = http.createServer((req, res) => {
  const proxy = http.request({
    hostname: UP_HOST, port: UP_PORT,
    path: req.url, method: req.method, headers: req.headers,
  }, (upstream) => {
    res.writeHead(upstream.statusCode, upstream.headers);
    upstream.pipe(res);
  });
  proxy.on('error', () => { res.writeHead(502); res.end('Bad Gateway'); });
  req.pipe(proxy);
});

// WebSocket: use raw TCP tunnel (CONNECT-style)
server.on('upgrade', (req, clientSocket, head) => {
  const upSocket = net.connect(UP_PORT, UP_HOST, () => {
    // Replay the original HTTP upgrade request to upstream
    let raw = req.method + ' ' + req.url + ' HTTP/1.1\r\n';
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      raw += req.rawHeaders[i] + ': ' + req.rawHeaders[i+1] + '\r\n';
    }
    raw += '\r\n';
    upSocket.write(raw);
    if (head && head.length) upSocket.write(head);

    // Once upstream sends back the 101, pipe everything through
    upSocket.pipe(clientSocket);
    clientSocket.pipe(upSocket);
  });
  upSocket.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upSocket.destroy());
});

server.listen(8080, '0.0.0.0', () => {
  console.log('[nemokube-proxy] HTTP+WS proxy on 0.0.0.0:8080 -> ' + UP_HOST + ':' + UP_PORT);
});
"
