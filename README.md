# cesar-beat

Docker Compose lab for **license** and **vulnerability** scanning of software dependencies, with upload to a local **Dependency-Track** and integration with GitHub's native security features.

> Demo material for the talk **"O Ponto Cego da IA no DevOps: Quem paga a conta do código 'gerado'?"** by **Cristiane Apolinário** and **Rodrigo Brayner**, presented at [CESAR BEAT](https://doity.com.br/cesar-beat) (May 14–16, 2026, Recife, PE — track *AI, HPC & Cybersecurity*). Talk slot: **16h40**.

## Stack

Target app under analysis (`compose.yml`):

- **app** — NodeGoat (`OWASP/NodejsGoat`) — intentionally vulnerable
- **mongo** — MongoDB (NodeGoat backend)

Scanning platforms:

- **Dependency-Track** (`compose.yml`) — `dtrack-apiserver` + `dtrack-frontend`
- **DefectDojo** (`compose.defectdojo.yml`, separate file) — alternative dashboard

All ports bind to `127.0.0.1` only — never expose NodeGoat publicly.

## Prerequisites

- Docker + Docker Compose
- [just](https://github.com/casey/just) (`brew install just`)
- `jq` (`brew install jq`)
- `curl` (used by every recipe — preinstalled on macOS/Linux)
- ~6 GB free RAM and internet access (image pulls, NVD mirror, Trivy DB)
- Free TCP ports on `127.0.0.1`: `5050`, `9081`, `9082`, `18080`

## What's what *(brief)*

- **SBOM** — Software Bill of Materials: list of every dependency (version + license) inside an artifact.
- **CycloneDX** — open SBOM standard. All tools here speak it.
- **NodeGoat** — OWASP's intentionally vulnerable Node.js app — the target we scan.
- **Syft** ([Anchore](https://github.com/anchore/syft)) — CLI that emits SBOMs from container images (used by Dependency-Track for NVD vulnerability matching).
- **Trivy** ([Aqua Security](https://github.com/aquasecurity/trivy)) — CLI that scans images for vulnerabilities + license risks; emits JSON or CycloneDX.
- **Dependency-Track** ([OWASP](https://dependencytrack.org/)) — platform that ingests SBOMs, runs vulnerability analyzers (NVD, GHSA), enforces license policies, tracks components over time.
- **DefectDojo** ([OWASP](https://www.defectdojo.org/)) — vulnerability management dashboard; stores findings from many scanners (no component inventory).
- **NIST NVD API key** — free credential that lifts the NVD API rate limit from 5 req / 30s to 50 req / 30s. Speeds up the first NVD mirror inside Dependency-Track. Request at https://nvd.nist.gov/developers/request-an-api-key.

## Configuration *(optional)*

Lab defaults work out of the box. To override anything (admin passwords, NVD API key, DefectDojo encryption keys):

```bash
cp .env.example .env
# edit .env
```

Both `just` (via `set dotenv-load`) and `docker compose` read `.env` from the project root. Empty values fall back to defaults in `.justfile` / `compose.defectdojo.yml`. Vars worth filling:

- `NVD_KEY` — free key at https://nvd.nist.gov/developers/request-an-api-key. Picked up automatically during `just bootstrap` (see *Quick start*) to switch Dependency-Track to the NVD API 2.0 (much faster initial mirror).
- `DD_SECRET_KEY` / `DD_CREDENTIAL_AES_256_KEY` — generate with `openssl rand -base64 32` if you're running DefectDojo beyond localhost.

## Quick start

```bash
just up           # bring everything up
just bootstrap    # create Dependency-Track API key, save to .dt-apikey
just scan         # generate CycloneDX SBOM via Syft + upload to Dependency-Track
```

Access:

| Service | URL | Login |
|---|---|---|
| NodeGoat | http://localhost:5050 | — |
| Dependency-Track UI | http://localhost:9081 | `admin` / `Lab1234!` |
| Dependency-Track API | http://localhost:9082 | — |

In **Dependency-Track → Projects → nodegoat**:

- **Components** — detected packages with license
- **Policy Violations** — violations of the "fail on Copyleft" policy
- **Audit Vulnerabilities** — NVD vulns (only after the NVD mirror inside Dependency-Track completes)

## Copyleft licenses *(the demo's focus)*

Some open-source licenses (**copyleft**) require any derivative work to be released under the same terms. So if a closed-source product links against a GPL library, the product itself must be relicensed under GPL ("viral" effect). Most companies treat this as a legal/commercial risk and **block these licenses in their dependencies**.

By strength:

| Type | Examples | Risk |
|---|---|---|
| **Strong copyleft** | `GPL-2.0`, `GPL-3.0`, `AGPL-3.0` | Forces the entire product to be open-sourced |
| **Weak copyleft** | `LGPL-2.1`, `LGPL-3.0`, `MPL-2.0` | Only the modified library file must stay open |
| **Permissive** *(no copyleft)* | `MIT`, `BSD-2-Clause`, `BSD-3-Clause`, `Apache-2.0`, `ISC` | None — these are what companies prefer |

Trivy classifies copyleft as `restricted` and labels it **HIGH** severity (see `just trivy-license-high`). Dependency-Track ships a built-in `Copyleft` license group, which the `just policy-setup` recipe uses to create a policy that **fails the build** whenever a copyleft license is introduced.

In this lab the target image (NodeGoat on Alpine) carries copyleft OS packages — `busybox`, `git`, `libgcc`, `musl-utils`, etc. (all `GPL-2.0` / `LGPL-2.1`) — which is what the demo flags.

## Commands

```
just up               # docker compose up -d --build --wait
just stop             # pause (containers stopped, can resume fast with just up)
just down             # remove containers, KEEP volumes (DT db + NVD mirror preserved)
just logs             # tail container logs
just bootstrap        # create Dependency-Track API key + apply NVD_KEY from .env (no-op if NVD_KEY empty)
just dt-nvd-api       # re-apply NVD_KEY config (also chained by bootstrap)
just dt-nvd-progress  # tail NVD mirror progress in real time (~15min initial sync with key)
just policy-setup     # create the "fail on Copyleft" policy
just sbom             # Syft -> sbom.json (CycloneDX; builds image if missing)
just scan             # sbom + upload to Dependency-Track (chains dt-refresh-metrics)
just dt-refresh-metrics  # force portfolio metrics recompute (else DT only refreshes daily)
just dt-clean-projects   # delete all DT projects via API (resets dashboard, keeps NVD mirror + policies)
just trivy-json       # Trivy -> trivy.json (no upload; builds image if missing)
just trivy-license    # tabular Trivy license scan (no file output)
just trivy-license-high  # same as trivy-license but only HIGH/CRITICAL (copyleft)
just sync-manifests   # refresh nodegoat-manifests/{package.json,package-lock.json} from upstream
just open             # open NodeGoat + Dependency-Track in the browser
just clean            # tear down cesar-beat stack + remove volumes (wipes DT db + NVD mirror)
just nuke             # clean + remove external images (Syft, Trivy, Dependency-Track, Mongo)
just stop-all         # pause BOTH stacks (preserves containers and volumes)
just down-all         # remove containers from BOTH stacks, keep all volumes
just clean-all        # tear down BOTH stacks (cesar-beat + DefectDojo) — removes volumes
just nuke-all         # nuke + dd-nuke (everything: containers, volumes, all images)
```

---

## DefectDojo *(alternative dashboard)*

Second self-hosted option, complementary to Dependency-Track. Different compose file, different commands.

DefectDojo doesn't scan — it stores findings produced by external scanners. So we feed it **Trivy JSON** via the native `Trivy Scan` parser.

```bash
just dd-up         # bring up DefectDojo (first run pulls ~3GB of images)
just dd-bootstrap  # API token + product + engagement
just dd-scan       # Trivy JSON + upload to DefectDojo (builds image if missing)
just dd-open       # open in browser
```

Access:

| Service | URL | Login |
|---|---|---|
| DefectDojo | http://localhost:18080 | `admin` / `Lab1234!` |

Stack: nginx + uwsgi + celerybeat + celeryworker + initializer + postgres + valkey (7 containers, ~4 GB RAM). Docker images are official multi-arch (arm64 + amd64).

Object hierarchy in DefectDojo: **Product** (`cesar-beat`) → **Engagement** (`nodegoat`) → **Test** (one per `dd-scan` run) → **Findings**.

### DefectDojo commands

```
just dd-up            # docker compose -f compose.defectdojo.yml up -d --wait
just dd-stop          # pause DefectDojo (containers stopped, resume fast with dd-up)
just dd-down          # remove DefectDojo containers, KEEP volumes (Postgres data preserved)
just dd-logs          # tail DefectDojo logs
just dd-bootstrap     # API token + product + engagement
just dd-scan          # trivy-json + upload to DefectDojo (Trivy Scan parser)
just dd-open          # open DefectDojo in the browser
just dd-clean         # tear down DefectDojo + remove volumes + .dd-apitoken
just dd-nuke          # dd-clean + remove DefectDojo/postgres/valkey images
```

---

## GitHub integration (public repo)

Workflow: `.github/workflows/license-scan.yaml` — runs on push to `main` and on every pull request.

NodeGoat's source is cloned by the Dockerfile at build time, so it's not in this repo. To let GitHub's Dependabot, Dependency Graph and Dependency Review see the npm dependencies, we keep a copy of `package.json` and a generated `package-lock.json` under `nodegoat-manifests/`. Refresh them with:

```bash
just sync-manifests   # clones NodejsGoat, regenerates lock, copies into nodegoat-manifests/
```

Two CI jobs:

1. **`trivy-license`** — builds the image, generates a CycloneDX SBOM with Syft (`anchore/sbom-action`) and uploads it as the `sbom-cyclonedx` workflow artifact, runs Trivy with `--scanners license`, uploads SARIF to Code Scanning, posts a sticky PR comment with the findings table, and finally fails the job on any HIGH/CRITICAL Trivy finding. License gate.
2. **`dependency-review`** *(PR only)* — `actions/dependency-review-action@v5`. Fails the PR on any ≥ high vuln introduced by the diff, reading from `nodegoat-manifests/package-lock.json`.

### Demoing the dep-review license gate (`scripts/`)

NodeGoat's npm deps are all permissive (MIT/Apache/ISC), so `dependency-review` finds nothing to deny by default. To trigger the gate on demand, two idempotent scripts under `scripts/` add/remove `gpl-2.0-licensed@1.0.0` (a real npm package published as a license-policy fixture) to `nodegoat-manifests/`:

```bash
scripts/add-demo-gpl-dep.sh       # patches package.json + package-lock.json with a real GPL-2.0 dep
# git add nodegoat-manifests/ && git commit -m "demo: gpl dep" && git push
# → dep-review fails in the PR with: Denied: gpl-2.0-licensed@1.0.0 (GPL-2.0-only)

scripts/remove-demo-gpl-dep.sh    # cleans the dep out for the next demo run
```

Both scripts are jq-based and use set/delete operations, so re-running them is byte-identical to a single run. The package only matters as a fixture — it's a real published npm pkg whose license metadata GitHub can verify (which is why a hand-crafted "fake GPL" entry in the lockfile would *not* trigger the gate — `dependency-review-action` queries the npm registry, not the local lockfile's `license` field).

### Where findings show up in the PR

| Surface | What you see | Source |
|---|---|---|
| PR *Files changed* | Inline annotations | Trivy SARIF |
| PR *Conversation* | License table (sticky) | sticky-pull-request-comment |
| PR *Conversation* | Dep diff with vulns | dependency-review-action |
| PR *Checks* | One check per job | GitHub Actions |
| Workflow run *Summary* → Artifacts | Downloadable `sbom-cyclonedx` (CycloneDX JSON) | Syft via `anchore/sbom-action` |
| Repo *Security* → Code scanning | Persistent findings | Code Scanning |
| Repo *Security* → Dependabot | Dependency vulns | Dependabot (reads `nodegoat-manifests/`) |

### Repo setup

> ⚠️ **Before going public — irreversible exposure check:**
> - Making a repo public exposes **the entire git history**, not just the current state. Run `git log -p` (or use a tool like `gitleaks`/`trufflehog`) and confirm no real secrets, tokens or credentials were ever committed — including in `.env`, branches you forgot, or amended commits.
> - The committed values (`Lab1234!`, the placeholder `DD_SECRET_KEY` / `DD_CREDENTIAL_AES_256_KEY` in `compose.defectdojo.yml`) are **lab-only defaults**. If you also self-host this beyond `127.0.0.1`, rotate them via `.env` first.
> - NodeGoat is **intentionally vulnerable** — never expose the running services publicly.

1. **Make public** — *Settings → General → Danger Zone → Make public*
2. **Actions** — *Settings → Actions → General → Actions permissions* → "Allow all actions and reusable workflows" (third-party actions are used). The workflow grants its own `pull-requests: write` and `security-events: write` via the `permissions:` block, so the *Workflow permissions* default can stay on "Read repository contents".
3. **Code Scanning** — *Settings → Code security → Code scanning → Set up* (Default)
4. **Dependabot** — *Settings → Code security* → enable Dependency graph and Dependabot alerts (skip *security updates* — that auto-opens fix PRs, out of scope for this license-focused demo).
5. **Branch protection** *(optional)* — *Settings → Branches → Add rule* on `main`, require `trivy-license` and `dependency-review`
6. **First PR** — open a PR (e.g. bump a version in `nodegoat-manifests/package.json`); the workflow runs and annotations appear shortly after Code Scanning ingests the SARIF.
