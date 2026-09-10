# Poko worker (self-hosted)

Run the Poko automation worker on your own Linux VPS.

## Quick install

SSH into an **x64 Ubuntu/Debian** server (8GB RAM recommended), then:

```bash
curl -fsSL https://raw.githubusercontent.com/kushalpoddar/poko-worker/main/install.sh | bash
```

The script installs Docker if needed, asks for your Poko credentials, pulls the image, and starts the worker.

### Non-interactive

```bash
export POKO_TOKEN=lm_…
export POKO_WORKSPACE_ID=…
export POKO_API_KEY=poko_live_…
# optional:
# export POKO_PUBLIC_URL=https://video.example.com

curl -fsSL https://raw.githubusercontent.com/kushalpoddar/poko-worker/main/install.sh | bash
```

Get `POKO_TOKEN`, `POKO_WORKSPACE_ID`, and `POKO_API_KEY` from **Poko Motion → Settings → API**.

## After install

- **Local check:** `curl -H "Authorization: Bearer $POKO_API_KEY" http://127.0.0.1:8787/automations/v1/status`
- **Automations base URL:** `https://your-domain.com/automations/v1/...` (with TLS) or put your own reverse proxy in front of `127.0.0.1:8787`
- **Logs:** `cd ~/poko-worker && docker compose logs -f poko-worker`

## Requirements

- Linux x64 VPS with Docker (script installs it)
- 8GB RAM recommended
- Ports 80/443 open if using `POKO_PUBLIC_URL` (Caddy TLS)
