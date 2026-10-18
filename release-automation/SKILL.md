---
name: release-automation
description: Automate release tagging (Stable vX.Y.Z and Release Candidates vX.Y.Z-rc.N), CI/CD GitHub Actions pipelines, Deployment ID traceability (release-manifest.json), and server auto-update scripts for Windows Services (.NET Workers), Web Apps/APIs (Laravel, Node, React), Docker containers, and CLIs. Trigger when the user asks to automate deployments, set up release tags, track deployed versions/IDs, create an auto-updater, or publish a new RC/stable release.
---

# Release & Deployment Automation Skill

This skill equips AI coding agents (Claude Code, Antigravity, Cursor, Codex) to set up end-to-end **Release Tag automation (`Stable` & `RC`)**, **Deployment ID traceability**, and **zero-touch server auto-updaters** across any project type.

All helper scripts and templates live relative to this skill's directory (`<skill-dir>`):
- `<skill-dir>/scripts/detect-project.sh`: Detects project category, git remote (`owner/repo`), current branch, and latest tags.
- `<skill-dir>/scripts/cut-release.sh`: Creates and pushes the next `rc` (`vX.Y.Z-rc.N`) or `stable` (`vX.Y.Z`) tag safely.
- `<skill-dir>/references/`: Detailed category playbooks loaded on demand.
- `<skill-dir>/assets/`: Ready-to-copy workflows, PowerShell/Bash server managers, and C#/PHP/JS version helpers.

---

## Workflow

### Step 1: Detect Project Type & Git Context

Run `<skill-dir>/scripts/detect-project.sh` in the target repository (or inspect the workspace). It outputs JSON with:
- `category`: `windows-service` | `webapp-api` | `docker` | `cli`
- `repo`: `<owner>/<name>` detected from `git remote get-url origin` (never hard-code `owner/repo`)
- `latestStableTag`, `latestRcTag`, `currentBranch`
- `sensitiveConfigs`: detected local config files (`config.json`, `.env`, `appsettings.Production.json`) that **must never** be packaged into release artifacts or overwritten on the server.

### Step 2: Load the Category Reference & Copy Assets

Based on `category`, read **only** the relevant reference file from `<skill-dir>/references/` and adapt the templates from `<skill-dir>/assets/<category>/`:

| Category | When to use | Reference to read | Templates in `assets/<category>/` |
| :--- | :--- | :--- | :--- |
| **`windows-service`** | `.NET Worker Service` (`UseWindowsService`), SAP B1 integrations, background daemons on Windows Server | `references/windows-service.md` | `DeploymentInfo.cs`, `github-workflow-release.yml`, `Manage-WindowsService.ps1` |
| **`webapp-api`** | Laravel/PHP, Node.js, .NET Web API, React/Next/Vue SPAs deployed on Linux/Nginx/IIS | `references/webapp-api.md` | `github-workflow-web-release.yml`, `manage-webapp.sh` |
| **`docker`** | Dockerized microservices, `docker-compose.yml`, GHCR (`ghcr.io`), Kubernetes | `references/docker.md` | `Dockerfile.snippet` |
| **`cli`** | Console utilities, batch ETLs, single-file executables | `references/cli.md` | Single-file publish commands & `--version` check |

> For branching (`develop` vs `master`), token setup (`GITHUB_TOKEN`), and PR formatting rules, read `references/versioning-strategy.md`.

### Step 3: Enforce the 4 Non-Negotiable Architecture Rules

Whenever you implement or update release automation in a project, ensure all 4 rules hold:

1. **Two Channels Driven by Git Tags (`rc` vs `stable`):**
   - Tags with a hyphen (`v1.2.0-rc.1`) are cut from `develop`, stamped with `"channel": "rc"` and prefix `RC-` in `deploymentId`, and published to GitHub Releases with `prerelease: true`.
   - Tags without a hyphen (`v1.2.0`) are cut from `master`/`main`, stamped with `"channel": "stable"` and prefix `REL-` in `deploymentId`, and published with `prerelease: false` (`Latest Release`).
   - Production servers subscribed to `stable` query `/releases/latest` (which natively ignores all `-rc.*` pre-releases). QA/Staging servers subscribed to `rc` query `?per_page=10` to pick up RCs immediately.

2. **The Universal `release-manifest.json` Contract:**
   Every release build must embed `release-manifest.json` in the artifact root:
   ```json
   {
     "releaseTag": "v3.0.0-rc.2",
     "channel": "rc",
     "deploymentId": "RC-v3.0.0-rc.2-46a4fdb-20261018-123345",
     "commitSha": "46a4fdb",
     "publishedAtUtc": "20261018T12:33:45Z",
     "installedAtLocal": ""
   }
   ```
   And the application must expose this identity via CLI (`App.exe --version`), startup logs (`STARTUP_dd.log`), or HTTP (`GET /api/version` / `/version.json`).

3. **Zero-Config-Clobber & Automatic Backups:**
   - CI/CD workflows must strip local `config.json` / `.env` before archiving.
   - Server update scripts (`Manage-WindowsService.ps1` / `manage-webapp.sh`) must exclude `config.json`, `.env`, `autoupdate-settings.json`, and `deployments-history.log` when extracting, and create a timestamped backup before stopping the service so `rollback` is a 1-command operation.

4. **Channel-Aware Scheduled Auto-Update (`stable` vs `rc`):**
   - Server scripts must persist the subscribed channel (`stable` or `rc`) in `autoupdate-settings.json` and provide commands to register a background task (`Register-ScheduledTask` as `SYSTEM` on Windows, or `crontab` on Linux) and switch channels on the fly (`set-channel`).

---

## Cutting a New Release Tag (`rc` or `stable`)

When the user asks to "create a new RC tag", "bump the RC", or "publish a stable release":
1. Ensure all unit tests pass (`dotnet test`, `npm test`, `vendor/bin/phpunit`) and changes are committed and pushed.
2. Run `<skill-dir>/scripts/cut-release.sh <rc|stable> [vX.Y.Z]`:
   - For `rc`: merges/checks `develop`, auto-increments `-rc.N` if `vX.Y.Z-rc.*` already exists, creates an annotated tag, and pushes it to `origin`.
   - For `stable`: checks `master`/`main`, creates annotated tag `vX.Y.Z`, and pushes it to `origin`.
3. Verify the GitHub Actions run (`gh run list --limit 3`) and confirm the `.zip`/`.tar.gz` asset and `release-manifest.json` are attached to the GitHub Release (`gh release view <tag> --json assets`).
