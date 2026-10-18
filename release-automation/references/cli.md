# 05. Automatización para Herramientas CLI, Scripts y Cron Jobs (`Single-File Executables`)

Para herramientas de consola (ej. `ResetDocsTool`, migradores de datos, ETLs programados por tarea/cron que no corren como un demonio continuo sino por ejecución), la mejor práctica es compilarlos como un **ejecutable único (`PublishSingleFile=true`)** con verificación de versión al arrancar.

---

## 1. Compilación Single-File con Trazabilidad (.NET / Go / Rust)

En `.NET`:
```bash
dotnet publish ResetDocsTool/ResetDocsTool.csproj \
  -c Release \
  -r win-x64 \
  --self-contained false \
  -p:PublishSingleFile=true \
  -p:Version=1.0.0 \
  -p:ReleaseTag=v1.0.0 \
  -p:SourceRevisionId=$(git rev-parse --short HEAD) \
  -o ./publish_cli
```

---

## 2. Patrón `--version` y `--check-update`

Cualquier herramienta CLI debe soportar dos banderas estándar:
1. `tool.exe --version`: Imprime el `ReleaseTag`, `Channel`, `DeploymentId` y `CommitSha`.
2. `tool.exe --check-update`: Consulta `https://api.github.com/repos/owner/repo/releases/latest` (o `?per_page=1` si está en canal `rc`) e informa si existe un Release más reciente antes de ejecutar un proceso crítico sobre la base de datos.
