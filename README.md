# 🚀 Release & Deployment Automation (AI Skill & Playbooks)

Un **AI Agent Skill (`release-automation`)** y biblioteca de playbooks para automatizar el ciclo de vida de releases basados en **Git Tags (`Stable vX.Y.Z` y `Release Candidates vX.Y.Z-rc.N`)**, trazabilidad por **`Deployment ID` (`release-manifest.json`)** y auto-actualización desatendida para **Servicios de Windows (.NET Workers)**, **Aplicaciones Web / APIs (Laravel, Node.js, React)**, **Docker** y **Herramientas CLI**.

Compatible con **Claude Code**, **Google Antigravity**, **Cursor**, **Codex** y el instalador estándar `npx skills`.

---

## 🤖 Instalación como AI Skill (Para Cualquier Agente)

### Opción 1: Instalación Global con `npx skills` (Claude Code / Cursor / Antigravity)
```bash
npx skills add https://github.com/kapb94/release-automation-playbooks -g -y
```

### Opción 2: Instalación Directa en Antigravity / Claude Code
```bash
# Para Google Antigravity:
git clone https://github.com/kapb94/release-automation-playbooks.git /tmp/rel-skill && \
  cp -r /tmp/rel-skill/release-automation ~/.gemini/config/skills/release-automation

# Para Claude Code:
cp -r /tmp/rel-skill/release-automation ~/.claude/skills/release-automation
```

### Cómo Invocar el Skill en tu Agente de IA
Simplemente pídele en lenguaje natural o con `/release-automation`:
- *"Configura la automatización de releases por tags (RC y Stable) y el script de auto-update para este servicio de Windows"*
- *"Agrega `/api/version` con `release-manifest.json` y el workflow de despliegue para esta API"*
- *"Crea el siguiente tag RC desde `develop` y publícalo en GitHub Releases"*

---

## 🗂️ Estructura del Repositorio

```text
release-automation-playbooks/
├── release-automation/                  # 🧠 AI AGENT SKILL (Estándar SKILL.md)
│   ├── SKILL.md                         # Frontmatter + Flujo paso a paso para IAs
│   ├── scripts/
│   │   ├── detect-project.sh            # Autodetecta categoría, repo y últimos tags -> JSON
│   │   └── cut-release.sh               # Incrementa y publica tags RC (vX.Y.Z-rc.N) o Stable
│   ├── references/                      # Documentación cargada bajo demanda por el agente
│   │   ├── versioning-strategy.md
│   │   ├── windows-service.md
│   │   ├── webapp-api.md
│   │   ├── docker.md
│   │   └── cli.md
│   └── assets/                          # Plantillas listas para inyectar en proyectos
│       ├── windows-service/
│       │   ├── DeploymentInfo.cs
│       │   ├── github-workflow-release.yml
│       │   └── Manage-WindowsService.ps1
│       └── webapp-api/
│           ├── github-workflow-web-release.yml
│           └── manage-webapp.sh
├── 01-versioning-strategy/              # 📖 Guía Humana: SemVer, RC vs Stable, Tokens y PRs
├── 02-windows-services/                 # 📖 Guía Humana: Servicios de Windows (.NET Workers)
├── 03-web-apps-and-apis/                # 📖 Guía Humana: Web Apps / APIs (Zero-Downtime Symlinks)
├── 04-docker-and-containers/            # 📖 Guía Humana: Contenedores Docker y GHCR
└── 05-cli-and-cron-jobs/                # 📖 Guía Humana: Ejecutables CLI Single-File
```

---

## 🎯 Los 4 Pilares que Automatiza Este Skill

1. **Dos Canales Controlados por Git Tags (`rc` y `stable`):**
   - `vX.Y.Z-rc.N` (desde `develop`) $\rightarrow$ `prerelease: true` en GitHub Releases (`Deployment ID: RC-...`).
   - `vX.Y.Z` (desde `master`/`main`) $\rightarrow$ `Latest Release` en GitHub Releases (`Deployment ID: REL-...`).
2. **Contrato Universal `release-manifest.json`:**
   - Todo artefacto incluye `releaseTag`, `channel`, `deploymentId`, `commitSha`, `publishedAtUtc` e `installedAtLocal`, consultable por CLI (`--version`), logs de arranque o endpoint HTTP (`/api/version`).
3. **Protección de Configuración y Rollback Instantáneo:**
   - Excluye `config.json` y `.env` del paquete de release y del despliegue, creando un backup automático previo para hacer `rollback` en un solo comando.
4. **Auto-Actualización Suscrita por Canal:**
   - Configura una Tarea Programada de Windows (`Manage-WindowsService.ps1 -Action register-autoupdate -Channel rc|stable`) o un Cron en Linux (`manage-webapp.sh register-cron`) que vigila únicamente el canal asignado a ese servidor.
