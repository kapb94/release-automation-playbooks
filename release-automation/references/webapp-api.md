# 03. Automatización para Aplicaciones Web y APIs (Laravel, Node.js, .NET Web API, React/SPA)

En proyectos Web y APIs (como `api`, `front-office`, `back-office`), el objetivo es desplegar mediante **Release Tags (`stable` y `rc`)** con **Zero-Downtime (cero tiempo de caída)** usando enlaces simbólicos (**Atomic Symlink Switching**) y exponer la identidad del despliegue en un endpoint `/api/version` (o `/version.json` en SPAs).

---

## 1. Arquitectura de Directorios Zero-Downtime (Linux / Nginx / IIS)

En lugar de sobrescribir archivos mientras los usuarios están haciendo peticiones HTTP, cada Release se descomprime en su propia carpeta inmutable y se cambia el symlink `current` en una operación atómica de milisegundos:

```text
/var/www/mi-api/
├── .env                          # Configuración compartida de producción (NUNCA se toca)
├── storage/                      # Carpeta persistente de archivos/logs
├── autoupdate-settings.json      # Canal suscrito ("stable" o "rc")
├── deployments-history.log       # Bitácora de auditoría de todos los despliegues
├── current -> releases/v1.2.0/   # Symlink activo al que apunta Nginx / Apache / PM2
└── releases/
    ├── v1.1.0/
    │   └── release-manifest.json
    ├── v1.2.0-rc.1/
    │   └── release-manifest.json
    └── v1.2.0/
        └── release-manifest.json
```

* **Actualización:** Se descarga `v1.2.0.tar.gz` $\rightarrow$ se extrae en `releases/v1.2.0/` $\rightarrow$ se enlaza `.env` $\rightarrow$ se corren migraciones $\rightarrow$ `ln -sfn releases/v1.2.0 current` $\rightarrow$ recarga suave de PHP-FPM / PM2 / Nginx.
* **Rollback instantáneo (< 1 segundo):** Apuntar `current` de vuelta a `releases/v1.1.0/`.

---

## 2. Exponer la Versión y el `Deployment ID` vía HTTP (`/api/version`)

Para saber desde el navegador, Postman o un monitor externo qué versión exacta tiene cada ambiente (`develop/staging` vs `production`):

### A. En Laravel / PHP (`routes/api.php`)
```php
Route::get('/version', function () {
    $manifestPath = base_path('release-manifest.json');
    if (file_exists($manifestPath)) {
        return response()->json(json_decode(file_get_contents($manifestPath), true));
    }
    return response()->json([
        'releaseTag'   => config('app.version', 'local'),
        'channel'      => app()->environment(),
        'deploymentId' => 'LOCAL-DEV',
    ]);
});
```

### B. En Node.js / Express / NestJS
```javascript
app.get('/api/version', (req, res) => {
  const fs = require('fs');
  const path = require('path');
  const manifestPath = path.join(process.cwd(), 'release-manifest.json');
  if (fs.existsSync(manifestPath)) {
    return res.json(JSON.parse(fs.readFileSync(manifestPath, 'utf8')));
  }
  return res.json({ releaseTag: 'v0.0.0-local', channel: 'local', deploymentId: 'LOCAL' });
});
```

### C. En Frontend SPA (React / Next.js / Vue)
Durante el build en GitHub Actions, `release-manifest.json` se copia dentro de `public/version.json` (o `dist/version.json`), de modo que `https://tu-dominio.com/version.json` devuelve el `releaseTag`, `channel` y `deploymentId` activos.

---

## 3. Archivos de Plantilla en Esta Carpeta

- **[`templates/github-workflow-web-release.yml`](./templates/github-workflow-web-release.yml):** Workflow de GitHub Actions que construye el proyecto web/API al detectar un tag `v*.*.*` (`stable` o `-rc.*`), inyecta `release-manifest.json` y publica el `.tar.gz` en GitHub Releases.
- **[`templates/manage-webapp.sh`](./templates/manage-webapp.sh):** Script Bash para servidores Linux con soporte para:
  - `./manage-webapp.sh status`
  - `./manage-webapp.sh update --channel rc` o `--channel stable`
  - `./manage-webapp.sh register-cron --channel rc --interval 10` (configura el cron job automático para el canal elegido)
  - `./manage-webapp.sh set-channel stable`
  - `./manage-webapp.sh rollback`
