# Poko worker (self-hosted)

Run the Poko automation worker on your own Linux VPS.

## 1. Point DNS first

On an **x64 Ubuntu/Debian** VPS (8GB RAM recommended), note the public IP, then at your DNS host:

```
A    video.yourdomain.com    →    <VPS public IP>
```

Open ports **80** and **443** (and 22 for SSH).

Wait until the name resolves **from your laptop**:

```bash
dig +short video.yourdomain.com
```

It must print the VPS IP. Do not run the installer until it does.

## 2. Install

SSH into the VPS, then:

```bash
curl -fsSL https://raw.githubusercontent.com/kushalpoddar/poko-worker/main/install.sh -o install.sh
bash install.sh
```

The script asks for:

1. **Public URL** — `video.yourdomain.com` or `https://video.yourdomain.com` (trimmed; Caddy + TLS start automatically)
2. **POKO_TOKEN**, **POKO_WORKSPACE_ID**, **POKO_API_KEY** — from **Poko Motion → Settings → API**

It checks that the hostname points at this box, then installs Docker if needed, pulls the image, and starts the worker + Caddy.

### Non-interactive

```bash
export POKO_PUBLIC_URL=https://video.yourdomain.com
export POKO_TOKEN=lm_…
export POKO_WORKSPACE_ID=…
export POKO_API_KEY=poko_live_…

curl -fsSL https://raw.githubusercontent.com/kushalpoddar/poko-worker/main/install.sh -o install.sh
bash install.sh
```

## 3. After install

- **Public:** `https://video.yourdomain.com/automations/v1/status` (Bearer `POKO_API_KEY`)
- **Automations base URL:** `https://video.yourdomain.com/automations/v1/...`
- **Logs:** `cd ~/poko-worker && docker compose logs -f poko-worker`
