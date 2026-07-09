# 🪶 Hermes Agent — Self-Hosting on Render Free Tier

> **Persistent state via Supabase Storage, kept warm with UptimeRobot.**

This repository contains a thin Docker wrapper around the official
[Hermes Agent](https://github.com/NousResearch/hermes-agent) image that adds
automatic backup and restore of the SQLite state database to Supabase Storage.
This solves two fundamental problems with Render's Free Tier:

| Problem | Solution |
|---|---|
| No persistent disk volumes on Free Tier | Upload `state.db` to Supabase Storage every N minutes |
| Service spins down after 15 min of inactivity | UptimeRobot pings the health endpoint every 5 minutes |
| State lost on redeployment | Entrypoint downloads latest backup before Hermes starts |

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│  Render Free Tier Web Service                        │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  Docker Container (hermes-custom)              │  │
│  │                                                │  │
│  │  entrypoint.sh                                 │  │
│  │   ├─ 1. Download state.db from Supabase        │  │
│  │   ├─ 2. Start `hermes gateway run` (bg)        │  │
│  │   ├─ 3. Backup loop every N minutes ──────────┼──┼──► Supabase Storage
│  │   └─ 4. SIGTERM → final upload → exit         │  │    (hermes-state bucket)
│  │                                                │  │
│  │  Ports: 8642 (API/health), 9119 (dashboard)   │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
         ▲
         │  HTTP ping every 5 min
         │
    UptimeRobot
```

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed locally
- A [Supabase](https://supabase.com) account (free tier is sufficient)
- A [Render](https://render.com) account
- A [Docker Hub](https://hub.docker.com) or [GHCR](https://docs.github.com/en/packages) account
- An [UptimeRobot](https://uptimerobot.com) account (free)

---

## Step 1 — Supabase Setup

### 1.1 Create the Storage Bucket

1. Log in to [app.supabase.com](https://app.supabase.com) and open your project.
2. In the left sidebar, click **Storage**.
3. Click **New bucket**.
4. Set the bucket name to `hermes-state`.
5. Leave **Public bucket** toggle **OFF** (private is safer for `.env` backups).
6. Click **Save**.

### 1.2 Grab Your Credentials

Go to **Project Settings → API** and note down:

| Value | Where to find it | Used for |
|---|---|---|
| **Project URL** | `https://xxxxxxxxxxxx.supabase.co` | `SUPABASE_URL` env var |
| **service_role secret** | Under *Project API keys → service_role* | `SUPABASE_SERVICE_KEY` env var |

> **WARNING:** The `service_role` key bypasses all Row Level Security policies.
> Never expose it in client-side code or public repositories.
> Pass it only through Render's encrypted environment variables.

---

## Step 2 — Local Build and Test

### 2.1 Clone and Configure

```bash
git clone https://github.com/YOUR_USERNAME/hermes-agent-render.git
cd hermes-agent-render

cp .env.example .env.local
# Edit .env.local with your real values
```

### 2.2 Build and Run

```bash
docker compose up --build
```

**Expected log output (first run):**

```
[...] [INFO]  Hermes Agent — Supabase State Sync Entrypoint Starting
[...] [WARN]  Remote file not found (404) — first run or empty bucket. Skipping.
[...] [INFO]  Hermes gateway started (PID 42)
[...] [INFO]  === Running state backup ===
[...] [INFO]  Upload successful (HTTP 200): state.db
```

### 2.3 Verify Health Endpoint

```bash
curl http://localhost:8642/health
# Expected: {"status":"ok"}
```

### 2.4 Verify Backup in Supabase

Go to **Supabase → Storage → hermes-state**.
After ~1 minute you should see `state.db` has appeared.

### 2.5 Test Restore on Restart

```bash
# Stop the container (triggers SIGTERM → final backup)
docker compose down

# Restart — it should download the backup on boot
docker compose up
```

Look for `Download successful: /opt/data/state.db` in the logs — the state has
been restored from Supabase.

---

## Step 3 — Push Image to a Registry

### Option A: Docker Hub

```bash
docker login
docker tag hermes-custom:local YOUR_DOCKERHUB_USERNAME/hermes-agent:latest
docker push YOUR_DOCKERHUB_USERNAME/hermes-agent:latest
```

### Option B: GitHub Container Registry (GHCR)

```bash
# Create a Personal Access Token with write:packages scope at
# https://github.com/settings/tokens/new
export CR_PAT=ghp_YOUR_TOKEN
echo $CR_PAT | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

docker tag hermes-custom:local ghcr.io/YOUR_GITHUB_USERNAME/hermes-agent:latest
docker push ghcr.io/YOUR_GITHUB_USERNAME/hermes-agent:latest
```

> **TIP:** Alternatively, push this repo to GitHub and choose
> *"Build from a Git repository"* in Render — Render will run `docker build`
> for you without needing a registry account.

---

## Step 4 — Deploy on Render

### 4.1 Create a New Web Service

1. Go to [dashboard.render.com](https://dashboard.render.com).
2. Click **New → Web Service**.
3. Choose **"Deploy an existing image"** (paste your image URL)
   or **"Build from Git repo"** (connect your repository).
4. Name the service `hermes-agent`.
5. Select **Free** instance type.

> **IMPORTANT — 750-Hour Monthly Cap:**
> Render Free Tier grants **750 instance hours per month** shared across all
> Free Tier services. One service running 24/7 uses ~744 hours in a 31-day
> month. If you have other active Free Tier services, you may hit the cap
> before month-end and all services stop. Monitor usage at
> **Render Dashboard → Billing**.

### 4.2 Environment Variables

Add the following in the **Environment** tab:

| Variable | Value | Notes |
|---|---|---|
| `SUPABASE_URL` | `https://xxxx.supabase.co` | From Supabase project settings |
| `SUPABASE_SERVICE_KEY` | `eyJ...` | `service_role` key — keep secret |
| `SUPABASE_BUCKET` | `hermes-state` | Must match bucket name exactly (case-sensitive) |
| `API_SERVER_KEY` | `<random 32+ char string>` | Generate: `openssl rand -hex 32` |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | `admin` | Username to access your admin dashboard at `/sessions` |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | `<your-password>` | Password to access the admin dashboard |
| `BACKUP_INTERVAL_MINS` | `5` | Minutes between state.db uploads |
| `DISABLE_DASHBOARD` | `false` | Set to `true` to disable the Web UI dashboard and save ~150MB of RAM for the Render free tier |
| `OPENROUTER_API_KEY` | `sk-or-...` | Get yours at [openrouter.ai/keys](https://openrouter.ai/keys) |
| `GROQ_API_KEY` | *(optional)* | For Groq's high-speed free tier — [console.groq.com/keys](https://console.groq.com/keys) |
| `GEMINI_API_KEY` | *(optional)* | Google Gemini API key — [aistudio.google.com](https://aistudio.google.com) |
| `GITHUB_TOKEN` | *(optional)* | GitHub Personal Access Token (for GitHub Models API) — [github.com/settings/tokens](https://github.com/settings/tokens) |
| `TELEGRAM_BOT_TOKEN` | *(optional)* | Only if using Telegram |
| `DISCORD_BOT_TOKEN` | *(optional)* | Only if using Discord |

> **Note:** API binding parameters (`API_SERVER_ENABLED`, `API_SERVER_HOST`, and `API_SERVER_PORT`) are managed automatically inside the entrypoint script. Do not configure them manually in Render.

### 4.3 Port and Health Check

- **Port:** `8642`
- **Health Check Path:** `/health`
- **Health Check Timeout:** `60s` (Hermes takes 10–20s to initialize)

### 4.4 Deploy

Click **Create Web Service** and monitor the **Logs** tab.

**First deploy:**
```
[...] [WARN]  Remote file not found (404) — first run or empty bucket. Skipping.
[...] [INFO]  Hermes gateway started (PID 7)
```

**Subsequent deploys (state restored from Supabase):**
```
[...] [INFO]  Download successful: /opt/data/state.db
[...] [INFO]  Hermes gateway started (PID 7)
```

---

## Step 5 — UptimeRobot Setup

Render Free Tier spins services down after **15 minutes of inactivity**.
UptimeRobot's free plan pings every 5 minutes — enough to keep the service warm.

### 5.1 Create a Monitor

1. Log in to [uptimerobot.com](https://uptimerobot.com).
2. Click **+ Add New Monitor**.
3. Configure:

   | Field | Value |
   |---|---|
   | Monitor Type | HTTP(s) |
   | Friendly Name | Hermes Agent |
   | URL | `https://YOUR-SERVICE.onrender.com/health` |
   | Monitoring Interval | 5 minutes |
   | Alert Contacts | Your email (recommended) |

4. Click **Create Monitor**.

> UptimeRobot's free plan allows up to **50 monitors** with 5-minute intervals —
> more than enough to keep a single Render service alive indefinitely.

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `SUPABASE_URL` | Yes | — | Supabase project URL |
| `SUPABASE_SERVICE_KEY` | Yes | — | Supabase service_role secret key |
| `SUPABASE_BUCKET` | Yes | `hermes-state` | Storage bucket name |
| `API_SERVER_KEY` | Yes | — | Bearer token for API authentication |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | No | `admin` | Username for dashboard Basic Auth |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | No | *(auto)* | Password for dashboard Basic Auth (generates securely on first boot if omitted) |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | No | *(auto)* | Signing secret for session tokens (prevents session expiration on container restarts) |
| `BACKUP_INTERVAL_MINS` | No | `5` | Minutes between state.db uploads |
| `DISABLE_DASHBOARD` | No | `false` | Set to `true` to disable the Web UI dashboard and save ~150MB of RAM for the Render free tier |
| `HERMES_DATA_DIR` | No | `/opt/data` | Path where Hermes stores its state |
| `OPENROUTER_API_KEY` | Yes | — | OpenRouter API key — [openrouter.ai/keys](https://openrouter.ai/keys) |
| `GROQ_API_KEY` | No | — | Groq API key (optional) — [console.groq.com/keys](https://console.groq.com/keys) |
| `GEMINI_API_KEY` | No | — | Google Gemini API key (optional, alias: `GOOGLE_API_KEY`) — [aistudio.google.com](https://aistudio.google.com) |
| `GITHUB_TOKEN` | No | — | GitHub Personal Access Token (for GitHub Models API) — [github.com/settings/tokens](https://github.com/settings/tokens) |
| `TELEGRAM_BOT_TOKEN` | No | — | Required only if using Telegram |
| `DISCORD_BOT_TOKEN` | No | — | Required only if using Discord |

> **Model selection is not an env var.** Use `hermes model` or the Hermes dashboard to choose your model after the agent starts. The choice is written to `config.yaml` inside `/opt/data/`, which `entrypoint.sh` backs up to Supabase Storage and restores on every restart — so your selection persists across redeploys automatically.

---

## Files in This Repository

```
hermes-agent-render/
├── Dockerfile            ← Custom image (base + curl + entrypoint)
├── entrypoint.sh         ← Backup/restore lifecycle wrapper
├── docker-compose.yml    ← Local testing only
├── .env.example          ← Template — copy to .env.local and fill in values
├── .gitignore            ← Keeps secrets out of Git
└── README.md             ← This file
```

---

## Troubleshooting

### Service fails health check on first deploy

Hermes takes 10–20s to initialize. Increase the Render health check timeout to
**60s**.

### 404 errors in the backup upload log

1. Verify `SUPABASE_URL` has no trailing slash.
2. Verify `SUPABASE_BUCKET` matches the bucket name exactly (case-sensitive).
3. Confirm you are using the `service_role` key (not the `anon` key).

### Gateway exits immediately on startup

At least one LLM provider API key must be set and valid.
Check that `OPENAI_API_KEY` (or equivalent) is present in your Render env vars.

### Service still spins down despite UptimeRobot

1. Verify the monitor URL uses `https://`.
2. Verify the URL path is `/health` and Hermes responds HTTP 200.
3. Confirm the UptimeRobot monitor is in **active** (not paused) state.

### API unreachable from outside the container

Ensure `API_SERVER_HOST=0.0.0.0` is set. The default `127.0.0.1` only allows
loopback connections and will make the service unreachable via Render's proxy.

---

## Upgrading Hermes

State lives in Supabase Storage, so upgrades are completely safe:

```bash
# Rebuild with the latest base image
docker build --pull -t YOUR_REGISTRY/hermes-agent:latest .
docker push YOUR_REGISTRY/hermes-agent:latest
```

Then in Render: **Manual Deploy → Deploy latest commit**.
The entrypoint will restore the latest `state.db` from Supabase before the new
version of Hermes starts.

---

## Security Checklist

- [ ] `SUPABASE_SERVICE_KEY` is stored only in Render's environment variables
- [ ] The `hermes-state` Supabase bucket is **private** (not public)
- [ ] `API_SERVER_KEY` is a long, cryptographically random string
- [ ] `.env` and `.env.local` are in `.gitignore` and have never been committed
- [ ] Your Git repository is private (or `.gitignore` has been double-checked)
