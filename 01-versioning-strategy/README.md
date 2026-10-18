# 01. Estrategia de Versionamiento, Ramas y Release Tags (`Stable` vs `RC`)

Esta guía define el estándar de ramas, etiquetas SemVer y formato de Pull Requests para controlar qué código corre en pruebas/QA y qué código corre en producción.

---

## 1. Estructura de Ramas

| Rama | Propósito | Canal de Release Asociado |
| :--- | :--- | :--- |
| `master` / `main` | Código estable de Producción. Solo recibe cambios mediante Pull Requests aprobados. | **`stable`** (`vX.Y.Z`) |
| `develop` | Rama de integración y pruebas (QA / Staging). | **`rc`** (`vX.Y.Z-rc.N`) |
| `feature/*` / `fix/*` | Ramas de trabajo diario que hacen PR hacia `develop` (y luego a `master`). | Ninguno (no se despliegan directo sin Tag) |
| `v1_legacy` | Respaldo congelado de versiones mayores anteriores (ej. antes de una migración de arquitectura). | Solo consulta / archivo |

---

## 2. Convención de Tags SemVer (`vX.Y.Z`)

Todo despliegue se origina creando un tag anotado de Git:

* **`MAJOR` (`X`):** Cambios de arquitectura o cambios incompatibles (ej. `v3.0.0`).
* **`MINOR` (`Y`):** Nuevas funcionalidades retrocompatibles (ej. `v3.1.0`).
* **`PATCH` (`Z`):** Correcciones de bugs o parches urgentes (ej. `v3.1.1`).
* **Sufijo `-rc.N` (Release Candidate):** Versiones candidatas generadas desde `develop` para probar en servidores de QA o validación antes de cerrar el PR a `master` (ej. `v3.0.0-rc.1`, `v3.0.0-rc.2`).

### Comandos Estándar de Liberación

#### A. Publicar un Release Candidate (Pruebas desde `develop`)
```bash
git checkout develop
git pull origin develop
git tag -a v1.2.0-rc.1 -m "Release Candidate v1.2.0-rc.1"
git push origin v1.2.0-rc.1
```
> Si corriges un bug durante las pruebas en `develop`, incrementas el contador RC: `v1.2.0-rc.2`.

#### B. Promover a Producción Estable (desde `master` / `main`)
Una vez que el `v1.2.0-rc.N` fue validado y el Pull Request hacia `master` fue mezclado:
```bash
git checkout master
git pull origin master
git tag -a v1.2.0 -m "Release Oficial v1.2.0"
git push origin v1.2.0
```

---

## 3. Cómo GitHub Actions Diferencia `RC` vs `Stable`

En todos nuestros workflows `.github/workflows/release.yml`, el paso de metadatos evalúa automáticamente si el nombre del tag contiene un guion (`-`):

1. **Si el tag contiene `-` (ej. `v1.2.0-rc.1`):**
   - `channel = "rc"`
   - `idPrefix = "RC"` $\rightarrow$ `DeploymentId = "RC-v1.2.0-rc.1-a1b2c3d-20261018-120000"`
   - En GitHub Releases se publica con **`prerelease: true`**.
   - El endpoint de GitHub `/repos/{owner}/{repo}/releases/latest` **NO devuelve este release**, protegiendo a todos los servidores de producción que consultan `/releases/latest`.

2. **Si el tag NO contiene `-` (ej. `v1.2.0`):**
   - `channel = "stable"`
   - `idPrefix = "REL"` $\rightarrow$ `DeploymentId = "REL-v1.2.0-f9e8d7c-20261018-160000"`
   - En GitHub Releases se publica con **`prerelease: false`** (convirtiéndose en el nuevo `Latest Release` oficial).

---

## 4. Configuración del Token de GitHub para Servidores (Lectura de Releases)

Para que un servidor (Windows o Linux) pueda consultar y descargar paquetes `.zip` o `.tar.gz` de un repositorio privado sin exponer credenciales de desarrollador:

1. Ir a **[GitHub Fine-grained Personal Access Tokens](https://github.com/settings/personal-access-tokens/new)**.
2. **Token name:** `Deploy-Reader-<NombreServidor>`
3. **Repository access:** `Only select repositories` $\rightarrow$ seleccionar el repositorio del proyecto.
4. **Repository permissions:**
   - `Contents`: **`Read-only`**
   - `Metadata`: **`Read-only`**
5. Guardar el token en el servidor a nivel de sistema:
   - **Windows (PowerShell como Administrador):**
     ```powershell
     [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", "github_pat_...", "Machine")
     ```
   - **Linux (`/etc/environment` o `/etc/default/app-updater`):**
     ```bash
     export GITHUB_TOKEN="github_pat_..."
     ```

---

## 5. Plantilla Estándar de Pull Request

Copia esta estructura en `.github/pull_request_template.md` de tus repositorios para mantener trazabilidad clara de los cambios entre ramas:

```markdown
## 📌 Pull Request

### 🧾 Description

<!-- Contexto de por qué se hace el cambio y qué problema resuelve. -->

**Cambios**
- 

**Endpoints / Integraciones afectadas**
- 

**Tests**
- 

---

### 🔗 Related Issue / Branches
- 

---

### 🛠️ Type of Change
- [ ] 🐛 Bug fix
- [ ] ✨ New feature
- [ ] ♻️ Refactor
- [ ] ⚡ Performance improvement
- [ ] 🧪 Tests
- [ ] 📚 Documentation
- [ ] 🔧 Configuration / DevOps
```
