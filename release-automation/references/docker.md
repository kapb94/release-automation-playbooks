# 04. Automatización para Contenedores Docker y Cloud (`Docker Compose` / `GHCR`)

Cuando un servicio o API se despliega como contenedor Docker, los mismos **Release Tags (`vX.Y.Z` y `vX.Y.Z-rc.N`)** construyen imágenes inmutables en **GitHub Container Registry (`ghcr.io`)** con etiquetas por canal (`:stable` y `:rc`).

---

## 1. Estrategia de Tags en Imágenes Docker

Cada vez que publicas un tag en Git, el workflow construye la imagen inyectando `release-manifest.json` y la etiqueta automáticamente según el canal:

| Git Tag Publicado | Etiquetas Generadas en `ghcr.io/owner/app` | Uso en Servidores |
| :--- | :--- | :--- |
| `v1.2.0-rc.1` | `:v1.2.0-rc.1`, `:rc` | Los entornos de **QA / Staging** apuntan a `image: ghcr.io/owner/app:rc` |
| `v1.2.0` | `:v1.2.0`, `:stable`, `:latest` | Los entornos de **Producción** apuntan a `image: ghcr.io/owner/app:stable` |

---

## 2. Inyección de Trazabilidad en el `Dockerfile`

Agrega estos `ARG` y `ENV` en tu `Dockerfile` para que el contenedor conozca su `Deployment ID` y `Release Tag` internamente:

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS runtime
WORKDIR /app

ARG RELEASE_TAG=v0.0.0-local
ARG CHANNEL=local
ARG DEPLOYMENT_ID=LOCAL
ARG COMMIT_SHA=local
ARG PUBLISHED_UTC=unknown

ENV APP_RELEASE_TAG=$RELEASE_TAG \
    APP_CHANNEL=$CHANNEL \
    APP_DEPLOYMENT_ID=$DEPLOYMENT_ID \
    APP_COMMIT_SHA=$COMMIT_SHA

LABEL org.opencontainers.image.version=$RELEASE_TAG \
      org.opencontainers.image.revision=$COMMIT_SHA \
      com.abaco.deployment.id=$DEPLOYMENT_ID \
      com.abaco.deployment.channel=$CHANNEL

COPY ./publish .
ENTRYPOINT ["dotnet", "App.dll"]
```

---

## 3. Auto-Actualización de Contenedores en el Servidor (`docker-compose.yml`)

Usando el canal `:stable` en Producción o `:rc` en QA, puedes actualizar o automatizar con un cron simple:

```bash
# Verificar si hay nueva imagen del canal suscrito (stable o rc) y recrear solo si cambió:
docker compose pull && docker compose up -d --remove-orphans
```
