# NKP Scuba Dive Log — Complete Reproduction Runbook

A step-by-step guide to rebuild this entire project from a clean laptop to a fully CI/CD-deployed app on Nutanix Kubernetes Platform. Captures every install, every command, and every gotcha encountered during the original 7-day sprint, so you (or a colleague) can repeat it without hunting for context.

> **Estimated time end-to-end:** ~10–14 hours of focused work, plus whatever lab admin requests take. Doable in a week if you have ~1–2 hours per day.

---

## Table of contents

1. [What you'll build](#what-youll-build)
2. [Prerequisites](#prerequisites)
3. [Phase 1 — Laptop toolchain](#phase-1)
4. [Phase 2 — Project skeleton + GitHub repo](#phase-2)
5. [Phase 3 — Backend (FastAPI)](#phase-3)
6. [Phase 4 — Frontend (HTML + nginx)](#phase-4)
7. [Phase 5 — Local containerized run](#phase-5)
8. [Phase 6 — Container registry (GHCR)](#phase-6)
9. [Phase 7 — NKP cluster preparation](#phase-7)
10. [Phase 8 — Helm chart + first deploy](#phase-8)
11. [Phase 9 — CI/CD pipeline](#phase-9)
12. [Phase 10 — Demo polish](#phase-10)
13. [Daily-use cheat sheet](#cheat-sheet)
14. [Gotchas summary table](#gotchas)
15. [Cleanup / teardown](#cleanup)
16. [Appendices: full file contents](#appendices)

---

## <a name="what-youll-build"></a>What you'll build

A full-stack scuba dive log:

- **Backend:** Python / FastAPI / SQLModel / SQLite
- **Frontend:** Vanilla HTML+JS+Tailwind served by nginx, proxying `/api/*` to backend
- **Local dev:** Podman Compose orchestrates both containers
- **Cluster:** NKP (Nutanix Kubernetes Platform) workload cluster, with Nutanix CSI storage and Traefik ingress via Kommander
- **Deploy:** Helm chart with Deployment×2, Service×2, PVC, ConfigMap, Ingress
- **CI/CD:** GitHub Actions with hybrid runners — public runner builds + pushes images to GHCR; self-hosted runner on the cluster bastion runs `helm upgrade`

---

## <a name="prerequisites"></a>Prerequisites

### On your laptop (macOS — Apple Silicon assumed)
- Admin / sudo access
- Homebrew installed (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`)
- A GitHub account
- Approval from IT/Security to install: Podman Desktop, Rancher Desktop, or equivalent (NOT Docker Desktop if your company blocks it — the licensing is the usual reason)

### On the bastion (Rocky Linux 9 / RHEL 9)
- SSH access as your own user (e.g., `miriam`)
- `git`, `kubectl`, `helm` already installed (NKP bastions usually have these)
- A working `kubeconfig` for the NKP cluster at a known path
- Internet access (to pull container images and to register a self-hosted GitHub Actions runner)

### Accounts and access
- GitHub account with permission to create public repos and packages
- An NKP workload cluster reachable from the bastion
- (Optional) Network access from your workstation to the cluster's LoadBalancer IP, via VPN or direct routing — if not, you'll use `kubectl port-forward` + SSH tunnel

---

## <a name="phase-1"></a>Phase 1 — Laptop toolchain (~30 min)

Install everything you'll need locally. Order matters slightly because some tools depend on others.

### 1.1 Install container runtime

```bash
# If Docker Desktop is allowed: brew install --cask docker
# Otherwise — use Podman Desktop (free, open-source, IT-friendly):
brew install podman
brew install --cask podman-desktop

# Initialize and start the Linux VM that hosts containers on macOS
podman machine init
podman machine start

# Verify
podman run --rm hello-world
```

> **Gotcha:** `podman compose` needs an external backend. Install it:
> ```bash
> brew install podman-compose
> podman compose version    # should print podman-compose 1.x and podman 5.x
> ```

> **Gotcha:** every time your laptop reboots or sleeps, the Podman VM stops. **`podman machine start` is the first command of every container session.** Make it muscle memory.

### 1.2 Install Kubernetes + Helm + Node + Python + Git CLIs

```bash
brew install kubectl kind helm node python@3.12 git gh
```

Verify:

```bash
kubectl version --client
kind version
helm version
node -v
python3.12 --version       # MUST be 3.12 — system python3 is often 3.9 and EOL
git --version
gh --version
```

> **Gotcha:** macOS bundles Python 3.9 as the system `python3`. Don't use it — FastAPI's modern type syntax (`X | None`) requires 3.10+. Always invoke explicitly as `python3.12`.

### 1.3 (Optional but recommended) Shell quality-of-life

```bash
# Oh My Zsh — gives you `ll` for `ls -la` and pretty themes
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Powerlevel10k theme
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
  ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
# Edit ~/.zshrc: set ZSH_THEME="powerlevel10k/powerlevel10k"

# Nerd Font for prompt icons
brew install --cask font-meslo-lg-nerd-font
# Then in iTerm: Settings → Profiles → Text → Font = MesloLGS NF
```

---

## <a name="phase-2"></a>Phase 2 — Project skeleton + GitHub repo (~10 min)

### 2.1 Authenticate `gh` and configure git identity

```bash
gh auth login                         # browser flow
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

> **Gotcha:** without `user.email` and `user.name`, `git commit` fails with `Author identity unknown`. Set these once, globally.

### 2.2 Create the repo and project skeleton

```bash
gh repo create nkp-scuba-divelog --public --clone
cd nkp-scuba-divelog

# Default branch — newer git defaults to "main"; if yours is on "master", rename:
git branch -M main

mkdir backend frontend deploy docs .github
touch backend/.gitkeep frontend/.gitkeep deploy/.gitkeep docs/.gitkeep

git add .
git commit -m "Initial project skeleton"
git push -u origin main
```

> **Gotcha:** The `-u` flag is important. It sets the upstream so future `git push` and `git pull` work without arguments.

---

## <a name="phase-3"></a>Phase 3 — Backend FastAPI app (~2 hours)

### 3.1 Set up Python virtualenv

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate           # prompt should now show (.venv)

cat > requirements.txt <<'EOF'
fastapi==0.115.0
sqlmodel==0.0.22
uvicorn[standard]==0.32.0
EOF

pip install --upgrade pip
pip install -r requirements.txt
```

> **Daily ritual:** every new terminal in this project starts with:
> ```bash
> cd ~/nkp-scuba-divelog/backend
> source .venv/bin/activate
> ```
> Otherwise `python` and `uvicorn` will not be found in `PATH`.

### 3.2 Create `.gitignore` so venv and SQLite don't pollute git

```bash
cat > .gitignore <<'EOF'
.venv/
__pycache__/
*.pyc
*.db
EOF
```

### 3.3 Create the application source files

Create `app/` with three Python files. See **[Appendix A](#appendix-a)** for the complete contents of:
- `backend/app/__init__.py` (empty)
- `backend/app/models.py`
- `backend/app/database.py`
- `backend/app/main.py`

> **CRITICAL gotcha:** In SQLModel, never use a single `table=True` class as both your database model AND your API request schema. The validation is *intentionally skipped* on `table=True` classes for ORM compatibility, which means string dates won't be parsed into Python `datetime` objects and your inserts will fail with `SQLite DateTime type only accepts Python datetime and date objects as input.`
>
> The canonical fix — used in this project — is to split each entity into four classes:
> - `XBase` (shared fields, no table)
> - `X` (the database table, inherits Base + `id` + relationships)
> - `XCreate` (input shape for POST, inherits Base)
> - `XRead` (output shape for GET, inherits Base + `id`)

### 3.4 Run locally

```bash
python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

> **Gotcha:** Use `python -m uvicorn ...` rather than bare `uvicorn ...`. The `python -m` form adds your current directory to `sys.path`, which is required when uvicorn's `--reload` mode spawns a subprocess to import your app module. The bare command will fail with `ModuleNotFoundError: No module named 'app'`.

Verify the API is alive by visiting **http://localhost:8000/docs** — you should see the FastAPI Swagger UI with sections for divers, sites, and dives. Test by:

1. **POST /divers** → `{"name": "Test", "cert_level": "Open Water"}`
2. **POST /sites** → `{"name": "Test Site", "country": "Brazil"}`
3. **POST /dives** → `{"date": "2026-05-10T09:00:00", "diver_id": 1, "site_id": 1, "duration_min": 45, "max_depth_m": 22.5}`
4. **GET /divers/1/stats** → returns computed stats

### 3.5 Containerize the backend

Create `backend/Dockerfile` and `backend/.dockerignore` — see **[Appendix C](#appendix-c)**.

```bash
# Build
podman build -t scuba-divelog-backend:0.1.0 .

# Run it standalone to verify (port 8000)
podman run --rm -p 8000:8000 --name scuba-backend scuba-divelog-backend:0.1.0

# Open http://localhost:8000/docs again — same Swagger, now from a container.
```

When verified, Ctrl+C to stop, then commit:

```bash
cd ~/nkp-scuba-divelog
git add backend/
git commit -m "FastAPI backend + Dockerfile"
git push
```

---

## <a name="phase-4"></a>Phase 4 — Frontend with nginx (~2 hours)

### 4.1 Enable CORS on the backend

In `backend/app/main.py`, add CORS middleware (a one-time edit). Add this import:

```python
from fastapi.middleware.cors import CORSMiddleware
```

And immediately after `app = FastAPI(...)`:

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],          # local dev — restrict in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

### 4.2 Create the frontend page

Create `frontend/index.html` — see **[Appendix B](#appendix-b)** for the full content. Key feature: the JavaScript detects whether it's served from nginx (port 8080) or directly, and routes API calls accordingly.

### 4.3 Create the nginx config and Dockerfile

Create `frontend/nginx.conf`, `frontend/Dockerfile`, and `frontend/.dockerignore` — see **[Appendix C](#appendix-c)**.

> **Gotcha:** the nginx `proxy_pass` directive proxies `/api/*` requests to the backend. The trailing slash on `proxy_pass http://backend:8000/` is critical — it strips `/api/` from the URL before forwarding (so `/api/sites` becomes `http://backend:8000/sites`). Without the trailing slash, the prefix is preserved and the backend gets `/api/sites` which doesn't exist.

### 4.4 Create the Compose file

Create `compose.yml` at the repo root — see **[Appendix C](#appendix-c)**.

### 4.5 Run the full stack locally

```bash
cd ~/nkp-scuba-divelog
podman compose up --build

# Open http://localhost:8080
```

You should see the scuba page with sections for Sites, Divers, Dives, Stats. Add a site, log a dive, click "Get Stats" — the data flows: browser → nginx → FastAPI → SQLite.

> **Gotcha:** if you previously served the frontend with `python -m http.server 8080`, your JavaScript may have cached an `/api` URL path that doesn't work outside the nginx container. The current `index.html` (see Appendix B) handles both cases.

> **Gotcha — "Cannot connect to Podman":** the Podman VM went to sleep. Fix:
> ```bash
> podman machine start
> ```

When working, commit:

```bash
git add frontend/ compose.yml backend/app/main.py
git commit -m "Frontend + nginx + compose for full-stack local run"
git push
```

---

## <a name="phase-5"></a>Phase 5 — Local containerized run (already done above)

Skipped — covered by Phase 4 step 4.5.

---

## <a name="phase-6"></a>Phase 6 — Push images to GHCR (~30 min)

### 6.1 Grant `gh` write access to packages

```bash
gh auth refresh -s write:packages    # browser flow
gh auth token | podman login ghcr.io -u <YOUR-GITHUB-USERNAME> --password-stdin
```

### 6.2 Build for `linux/amd64` and push

> **CRITICAL gotcha (Apple Silicon):** NKP nodes are typically `linux/amd64` (x86_64). Default `podman build` on an M-series Mac produces `linux/arm64` images. Pushed arm64 images will be pulled by the cluster *successfully*, then **crash on startup** with `exec format error`. Always use `--platform linux/amd64` when building for an Intel/AMD K8s cluster from an arm64 Mac.

```bash
cd ~/nkp-scuba-divelog

# Backend
podman build --platform linux/amd64 \
  -t ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-backend:0.1.0 \
  -t ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-backend:latest \
  ./backend

# Frontend
podman build --platform linux/amd64 \
  -t ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-frontend:0.1.0 \
  -t ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-frontend:latest \
  ./frontend

# Push all four tags
podman push ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-backend:0.1.0
podman push ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-backend:latest
podman push ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-frontend:0.1.0
podman push ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-frontend:latest
```

### 6.3 Make the packages public

Browser → https://github.com/`<YOUR-USERNAME>`?tab=packages → click each of the two packages → **Package settings → Danger Zone → Change visibility → Public**.

### 6.4 Verify unauthenticated pull works

```bash
podman logout ghcr.io
podman pull ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-backend:0.1.0
podman pull ghcr.io/<YOUR-GITHUB-USERNAME>/scuba-divelog-frontend:0.1.0
gh auth token | podman login ghcr.io -u <YOUR-GITHUB-USERNAME> --password-stdin
```

---

## <a name="phase-7"></a>Phase 7 — NKP cluster preparation (~variable)

Assumed: you already have an NKP workload cluster up. If not, ask your lab admin or follow the official NKP install docs — outside the scope of this runbook.

### 7.1 Persist your `KUBECONFIG` on the bastion

```bash
# On the bastion
echo 'export KUBECONFIG=$HOME/nkp-vX.Y.Z/<YOUR-CLUSTER>.conf' >> ~/.bashrc
echo 'export KUBECONFIG=$HOME/nkp-vX.Y.Z/<YOUR-CLUSTER>.conf' >> ~/.bash_profile
source ~/.bashrc

# Verify in any new shell
kubectl get nodes
```

> **Gotcha:** Without persistence, every new SSH session has no `KUBECONFIG` and `kubectl get pods` returns nothing useful — looking like your cluster "disappeared." Setting it in `.bashrc` AND `.bash_profile` covers both login and interactive shells.

### 7.2 Default kubectl to the app's namespace

After installing the chart (Phase 8), set the default namespace so plain `kubectl get pods` shows your scuba pods:

```bash
kubectl config set-context --current --namespace=scuba
```

### 7.3 Test cluster outbound egress to GHCR

```bash
kubectl run egress-test --image=nginx:alpine --restart=Never
sleep 5
kubectl get pod egress-test
# STATUS should be "Running" if egress works
kubectl delete pod egress-test
```

If the pod stays in `ImagePullBackOff`, your cluster has no internet egress and you'll need an internal registry (e.g., Harbor) instead of GHCR. Ask your lab admin.

### 7.4 Capture cluster facts you'll need

```bash
kubectl get storageclass        # note the DEFAULT one (here: nutanix-volume)
kubectl get ingressclass        # note the controller (here: kommander-traefik)
kubectl get svc -n kommander kommander-traefik   # note the EXTERNAL-IP (LoadBalancer)
```

Save these in `docs/lab-inventory.md` for your future reference.

---

## <a name="phase-8"></a>Phase 8 — Helm chart + first deploy (~2 hours)

### 8.1 Create the chart files

The full chart structure (12 files) is in **[Appendix D](#appendix-d)**. The fastest way to recreate them is via the `create-chart.sh` script in that appendix — save it as a file in your repo root and run:

```bash
cd ~/nkp-scuba-divelog
bash create-chart.sh
```

This generates `deploy/charts/scuba-divelog/` with all templates.

### 8.2 Edit `values.yaml` for your environment

Open `deploy/charts/scuba-divelog/values.yaml` and update:

```yaml
image:
  registry: ghcr.io/<YOUR-GITHUB-USERNAME>     # ← your GHCR namespace
```

Confirm that `backend.persistence.storageClassName` and `ingress.className` match what `kubectl get storageclass` and `kubectl get ingressclass` reported (defaults are `nutanix-volume` and `kommander-traefik` for NKP).

### 8.3 Commit, push, pull on the bastion

```bash
# Laptop
git add deploy/
git commit -m "Helm chart for NKP deployment"
git push

# Bastion
cd ~/nkp-scuba-divelog
git pull
```

### 8.4 Lint + render + install

```bash
# Sanity check (catches typos before talking to the API server)
helm lint deploy/charts/scuba-divelog

# Dry-render the templates so you see exactly what will be applied
helm template scuba deploy/charts/scuba-divelog --namespace scuba | less

# Install
helm install scuba deploy/charts/scuba-divelog \
  --namespace scuba \
  --create-namespace

# Watch pods come up
kubectl -n scuba get pods -w
```

### 8.5 Fix the PVC permissions error

When you first deploy, the backend pod will **CrashLoopBackOff** with this error in `kubectl -n scuba logs scuba-backend-... --previous`:

```
sqlite3.OperationalError: unable to open database file
```

> **Gotcha (the most common stateful-on-K8s issue):** the Dockerfile runs the container as `appuser` (UID 1000), but when the PVC mounts at `/data`, the mount replaces the directory with one owned by `root:root` (UID 0). The non-root user can't write to it, SQLite can't create the database file.
>
> **Fix:** add `securityContext` with `fsGroup: 1000` to the pod spec so the kubelet sets group ownership of the volume to GID 1000 at mount time.

The chart in Appendix D already includes this fix. If you're reading old notes that don't, the addition to `backend-deployment.yaml` is:

```yaml
    spec:
      securityContext:               # ← these 4 lines fix the PVC permission issue
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: backend
          # ...
```

After committing the fix:

```bash
# Laptop
git add deploy/charts/scuba-divelog/templates/backend-deployment.yaml
git commit -m "Fix backend PVC permissions: add fsGroup securityContext"
git push

# Bastion
git pull
helm upgrade scuba deploy/charts/scuba-divelog -n scuba
kubectl -n scuba get pods -w
```

The backend should stay `Running` this time.

### 8.6 Access the app

Grab the LoadBalancer IP:

```bash
kubectl get svc -n kommander kommander-traefik
# Note the EXTERNAL-IP (e.g., 10.54.27.133)
```

Browser → `https://<LOAD-BALANCER-IP>/`

> **Gotcha:** NKP's Traefik forces HTTP→HTTPS redirect, but the cluster ships with a self-signed certificate. Your browser will show a TLS warning. Click through (Advanced → Proceed). For a production fix, install `cert-manager` and a ClusterIssuer (see Phase 2 of the deeper-learning track).

> **Gotcha:** if your laptop can't route to `10.54.27.133` (lab-internal IP), open an SSH tunnel from your laptop to the bastion + run `kubectl port-forward`:
> ```bash
> # On laptop, in one terminal
> ssh -L 8080:localhost:8080 <user>@<bastion>
> # Once SSH'd in:
> kubectl -n scuba port-forward svc/scuba-frontend 8080:80
> # Then open http://localhost:8080 on your laptop
> ```

---

## <a name="phase-9"></a>Phase 9 — CI/CD pipeline (~2 hours)

### 9.1 Install a self-hosted GitHub Actions runner on the bastion

In GitHub: **repo → Settings → Actions → Runners → New self-hosted runner** → Linux x64. Copy the download URL and the registration token from the page (token is one-time).

```bash
# On the bastion
mkdir -p ~/actions-runner && cd ~/actions-runner

curl -o actions-runner-linux-x64.tar.gz -L <URL-FROM-GITHUB-PAGE>
tar xzf ./actions-runner-linux-x64.tar.gz

./config.sh \
  --url https://github.com/<YOUR-USERNAME>/nkp-scuba-divelog \
  --token <TOKEN-FROM-GITHUB-PAGE> \
  --name nkp-bastion \
  --labels self-hosted,linux,nkp,bastion \
  --work _work \
  --unattended

# Start it as a background process (survives SSH logout)
nohup ./run.sh > runner.log 2>&1 &
disown

# Verify it's listening
tail -f runner.log    # should say "Connected" and "Listening for Jobs"
ps aux | grep Runner.Listener
```

> **Gotcha — systemd install on Rocky Linux fails with `203/EXEC`:** SELinux blocks systemd from executing scripts in user home directories. Two options:
> - **Quick (recommended for sprints):** use `nohup ./run.sh &` as shown above. Survives SSH logout.
> - **Proper:** relabel the runner directory with SELinux's `bin_t` type:
>   ```bash
>   sudo dnf install -y policycoreutils-python-utils
>   sudo semanage fcontext -a -t bin_t "$HOME/actions-runner(/.*)?"
>   sudo restorecon -Rv "$HOME/actions-runner/"
>   sudo ./svc.sh install
>   sudo ./svc.sh start
>   ```

In GitHub's Runners page, you should now see `nkp-bastion` with green "Idle" status.

### 9.2 Create the workflow file

Create `.github/workflows/deploy.yml` — see **[Appendix E](#appendix-e)** for full content.

### 9.3 Grant the repo write access to your GHCR packages

> **Gotcha:** when GitHub Actions tries to push to GHCR for the first time, you'll get `denied: permission_denied: write_package`. This happens because your packages were created manually (Phase 6) under your *user* namespace, not as repo-owned packages. The auto-generated `GITHUB_TOKEN` doesn't have write access to user-namespace packages unless explicitly granted.
>
> **Fix:** for each of `scuba-divelog-backend` and `scuba-divelog-frontend`:
> - https://github.com/users/`<YOUR-USERNAME>`/packages/container/`<PACKAGE-NAME>`/settings
> - Scroll to "Manage Actions access"
> - "Add Repository" → select `nkp-scuba-divelog` → confirm (default role: Write)

### 9.4 Commit, push, watch the first run

```bash
git add .github/workflows/deploy.yml
git commit -m "CI/CD with GitHub Actions (hybrid runners)"
git push
```

Open https://github.com/`<YOUR-USERNAME>`/nkp-scuba-divelog/actions in your browser. Watch the workflow:

1. **Build job** runs on a GitHub-hosted runner. Builds both images with `--platform linux/amd64`, pushes to GHCR with `:sha` and `:latest` tags.
2. **Deploy job** runs on your self-hosted runner. Logs scroll in your bastion's `runner.log`. Runs `helm upgrade --install`. `--wait --timeout 5m` blocks until pods are healthy.

If both jobs go green, verify:

```bash
# On bastion
kubectl -n scuba get pods -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'
# Should show your images tagged with the commit SHA (not :0.1.0)
```

### 9.5 The celebratory test — push a change, watch it deploy

Edit `frontend/index.html` — change the subtitle text. Commit and push.

```bash
git add frontend/index.html
git commit -m "Update subtitle"
git push
```

Watch the workflow run. ~3-4 minutes later, refresh the scuba page in the browser. **The new subtitle appears, end-to-end automatic.**

---

## <a name="phase-10"></a>Phase 10 — Demo polish (~1.5 hours)

- Create an architecture diagram (SVG) in `docs/architecture.svg`. The file is in this project's outputs folder.
- Write a `README.md` at the repo root explaining what the project is. Template in this project's outputs folder.
- Write a 5-minute demo script in `docs/demo-script.md`. Template in this project's outputs folder.
- Record yourself running through the demo once (macOS QuickTime → New Screen Recording → full screen).

---

## <a name="cheat-sheet"></a>Daily-use cheat sheet

### Start a working session (laptop)

```bash
podman machine start                              # wake container runtime
cd ~/nkp-scuba-divelog/backend
source .venv/bin/activate
```

### Run local stack

```bash
cd ~/nkp-scuba-divelog
podman compose up --build                         # both containers, with rebuild
# Ctrl+C to stop
podman compose down                               # remove containers, keep data
podman compose down -v                            # also wipe SQLite volume
```

### Local backend only (for fast Python iteration)

```bash
cd ~/nkp-scuba-divelog/backend
source .venv/bin/activate
python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
# Browser: http://localhost:8000/docs
```

### Build + push images

```bash
podman build --platform linux/amd64 -t ghcr.io/<USER>/scuba-divelog-backend:0.1.0 ./backend
podman push ghcr.io/<USER>/scuba-divelog-backend:0.1.0
# (repeat for frontend)
```

### Cluster inspection (bastion)

```bash
kubectl -n scuba get pods                          # what's running
kubectl -n scuba describe pod <name> | tail -30    # why is it not running
kubectl -n scuba logs <name> --previous            # crashed container's last words
kubectl -n scuba get all,pvc,ingress               # everything at a glance
kubectl -n scuba port-forward svc/scuba-frontend 8080:80    # tunnel for browser
```

### Helm operations

```bash
helm list -n scuba                                 # see installed releases
helm upgrade scuba deploy/charts/scuba-divelog -n scuba    # apply chart changes
helm rollback scuba 1 -n scuba                    # revert to revision 1
helm uninstall scuba -n scuba                     # remove the app
```

---

## <a name="gotchas"></a>Gotchas summary table

| # | Gotcha | Symptom | Fix |
|---|--------|---------|-----|
| 1 | Podman machine sleeps | `Cannot connect to Podman socket` | `podman machine start` |
| 2 | Podman compose has no backend | `looking up compose provider failed` | `brew install podman-compose` |
| 3 | macOS system Python is 3.9 | FastAPI features error | Use `python3.12` explicitly; install with `brew install python@3.12` |
| 4 | git no identity set | `Author identity unknown` on commit | `git config --global user.name/email` |
| 5 | Default branch is `master` | `git push` rejects | `git branch -M main` then `git push -u origin main` |
| 6 | `uvicorn app.main:app --reload` fails | `ModuleNotFoundError: No module named 'app'` | Use `python -m uvicorn app.main:app --reload` |
| 7 | venv lost after laptop reboot | `command not found: python` | `source .venv/bin/activate` |
| 8 | SQLModel `table=True` skips validation | `SQLite DateTime type only accepts Python datetime` | Split into Base / Table / Create / Read classes |
| 9 | JS frontend gets 501 from Python http.server | "Unsupported method POST" | Hard-code `API_BASE = 'http://localhost:8000'` for local dev |
| 10 | Arm64 images crash on x86 nodes | `exec format error` in pod logs | Always `podman build --platform linux/amd64` for K8s targets |
| 11 | New SSH tab → kubectl shows nothing | Cluster "disappeared" | Persist `KUBECONFIG` in `~/.bashrc` AND `~/.bash_profile` |
| 12 | Pod crash with `unable to open database file` | Backend `CrashLoopBackOff` | Add `securityContext.fsGroup: 1000` to pod spec |
| 13 | Traefik HTTP→HTTPS redirect + self-signed cert | Browser shows blank page or cert warning | Click through cert warning, or add `cert-manager` (Phase 2) |
| 14 | Laptop can't reach lab IP | LoadBalancer URL doesn't load on laptop | SSH tunnel + `kubectl port-forward` |
| 15 | `gh` CLI lacks package permissions | `denied: write_package` | `gh auth refresh -s write:packages` |
| 16 | GitHub Actions can't push to GHCR | `denied: permission_denied: write_package` | Grant repo Write access in package settings |
| 17 | systemd refuses to start runner on Rocky | `status=203/EXEC` | Use `nohup ./run.sh &` OR `semanage fcontext -t bin_t` |

---

## <a name="cleanup"></a>Cleanup / teardown

### Remove the app from the cluster

```bash
# Bastion
helm uninstall scuba -n scuba
kubectl delete namespace scuba
```

> Note: `helm uninstall` does NOT delete the PVC by default (so data survives reinstalls). To wipe data:
> ```bash
> kubectl -n scuba delete pvc scuba-backend-data
> ```

### Stop the self-hosted runner

```bash
# Bastion
ps aux | grep Runner.Listener            # find the PID
kill <PID>
# Optionally remove the registration:
cd ~/actions-runner && ./config.sh remove --token <REMOVAL-TOKEN-FROM-GITHUB>
```

### Remove local containers and volumes

```bash
podman compose down -v                    # in repo root
podman rmi $(podman images -q)            # nuclear: remove ALL local images
podman machine stop                       # stop the VM
podman machine rm                         # delete the VM
```

### Remove GHCR packages

Browser → https://github.com/`<YOUR-USERNAME>`?tab=packages → click package → Package settings → Delete.

---

## <a name="appendices"></a>Appendices: full file contents

The appendices below contain every file you need. For larger files (Helm chart templates, the full backend code), they're referenced to the original repo at `github.com/<YOUR-USERNAME>/nkp-scuba-divelog` since this runbook focuses on commands and gotchas rather than re-pasting hundreds of lines.

**If you're rebuilding from scratch with no repo**, follow this order:

1. Pull the file contents from the appendix sections listed below (provided in this project's outputs folder as standalone files).
2. Each appendix corresponds to a directory or single file — recreate them in the project skeleton from Phase 2.

### <a name="appendix-a"></a>Appendix A — Backend Python source (`backend/app/`)

Three files: `models.py`, `database.py`, `main.py` (plus an empty `__init__.py`). All three are listed in this project's outputs folder.

Key file: `models.py` uses the **Base / Table / Create / Read** pattern for each of Diver, Site, Dive — see Phase 3 gotcha for why.

### <a name="appendix-b"></a>Appendix B — Frontend (`frontend/index.html`)

Single self-contained HTML file with Tailwind CSS via CDN and vanilla JavaScript using `fetch()`. The `API_BASE` constant near the top of the `<script>` block has a smart detection so it works both standalone (talking to `localhost:8000`) and inside the nginx container (talking to `/api/`).

### <a name="appendix-c"></a>Appendix C — Container & Compose files

- `backend/Dockerfile` — Python 3.12-slim, multi-stage friendly, runs as non-root `appuser` (UID 1000) with `/data` VOLUME.
- `backend/.dockerignore`
- `frontend/Dockerfile` — `nginx:1.27-alpine`, copies `index.html` and `nginx.conf`.
- `frontend/nginx.conf` — listens on 80, serves static at `/`, proxies `/api/*` to backend.
- `frontend/.dockerignore`
- `compose.yml` (at repo root) — orchestrates both services with internal network and named volume for SQLite.

### <a name="appendix-d"></a>Appendix D — Helm chart (`deploy/charts/scuba-divelog/`)

12 files total. The fastest way to recreate the entire chart is the `create-chart.sh` script saved in this project's outputs folder — it generates all 12 files via heredocs when run from the repo root.

Chart structure:

```
deploy/charts/scuba-divelog/
├── Chart.yaml
├── values.yaml
├── .helmignore
└── templates/
    ├── _helpers.tpl
    ├── backend-pvc.yaml          # PersistentVolumeClaim, 1Gi, nutanix-volume
    ├── backend-deployment.yaml   # Deployment, 1 replica, fsGroup:1000, Recreate strategy
    ├── backend-service.yaml      # ClusterIP Service on port 8000
    ├── frontend-configmap.yaml   # Overrides nginx.conf with K8s service name
    ├── frontend-deployment.yaml  # Deployment, 2 replicas
    ├── frontend-service.yaml     # ClusterIP Service on port 80
    ├── ingress.yaml              # kommander-traefik ingress, no host (catch-all)
    └── NOTES.txt
```

### <a name="appendix-e"></a>Appendix E — GitHub Actions workflow (`.github/workflows/deploy.yml`)

Single workflow with two jobs:

- **build** (runs on `ubuntu-latest`): Buildx + amd64 + push backend & frontend to GHCR tagged with short SHA + `latest`.
- **deploy** (runs on `[self-hosted, nkp]`): `helm upgrade --install` with `--set backend.image.tag=<sha>` and `--set frontend.image.tag=<sha>` and `--wait`.

Full content in this project's outputs folder.

---

## You did this

Seven days from "I haven't touched Kubernetes in two years" to "containerised app deployed via Helm on NKP with auto-deploy from a git push." Keep this runbook close — the next time someone asks "can you show me how a customer would deploy on NKP?" you have the full receipts.

> *Built by Miriam Gorino, Senior Solution Architect, Nutanix Kubernetes Platform — May 2026.*
