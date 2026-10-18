#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Gestor Zero-Downtime y Auto-Update por Release Tags (Stable & RC) para Web/APIs
# ==============================================================================
# Uso:
#   ./manage-webapp.sh status
#   ./manage-webapp.sh update [--channel stable|rc] [--tag v1.2.0]
#   ./manage-webapp.sh auto-update
#   ./manage-webapp.sh set-channel <stable|rc>
#   ./manage-webapp.sh register-cron <stable|rc> [interval_minutes]
#   ./manage-webapp.sh rollback
# ==============================================================================

ACTION="${1:-status}"
shift || true

APP_ROOT="${APP_ROOT:-/var/www/webapp}"
GITHUB_REPO="${GITHUB_REPO:-owner/repo}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
RELOAD_CMD="${RELOAD_CMD:-sudo systemctl reload nginx}"
CHANNEL_OVERRIDE=""
TARGET_TAG="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL_OVERRIDE="$2"; shift 2 ;;
    --tag) TARGET_TAG="$2"; shift 2 ;;
    --repo) GITHUB_REPO="$2"; shift 2 ;;
    --root) APP_ROOT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SETTINGS_FILE="${APP_ROOT}/autoupdate-settings.json"
HISTORY_FILE="${APP_ROOT}/deployments-history.log"
RELEASES_DIR="${APP_ROOT}/releases"
CURRENT_LINK="${APP_ROOT}/current"

mkdir -p "$RELEASES_DIR"

get_subscribed_channel() {
  if [[ -n "$CHANNEL_OVERRIDE" ]]; then
    echo "$CHANNEL_OVERRIDE"
    return
  fi
  if [[ -f "$SETTINGS_FILE" ]]; then
    grep -o '"subscribedChannel"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | cut -d'"' -f4 || echo "stable"
  else
    echo "stable"
  fi
}

save_subscribed_channel() {
  local ch="$1"
  cat > "$SETTINGS_FILE" <<EOF
{
  "subscribedChannel": "${ch}",
  "updatedAt": "$(date +"%Y-%m-%d %H:%M:%S")"
}
EOF
}

get_local_field() {
  local field="$1"
  local manifest="${CURRENT_LINK}/release-manifest.json"
  if [[ -f "$manifest" ]]; then
    grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$manifest" | cut -d'"' -f4 || echo "N/A"
  else
    echo "NO-INSTALADO"
  fi
}

fetch_remote_release_json() {
  local tag="$1"
  local channel="$2"
  local auth_header=()
  if [[ -n "$GITHUB_TOKEN" ]]; then
    auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  if [[ "$tag" == "latest" ]]; then
    if [[ "$channel" == "rc" ]]; then
      curl -fsSL "${auth_header[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=1" | sed -n '/^{/,/^}/p'
    else
      curl -fsSL "${auth_header[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    fi
  else
    curl -fsSL "${auth_header[@]}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}"
  fi
}

show_status() {
  local ch
  ch="$(get_subscribed_channel)"
  local local_tag
  local_tag="$(get_local_field releaseTag)"
  local local_id
  local_id="$(get_local_field deploymentId)"
  local local_ch
  local_ch="$(get_local_field channel)"

  echo "======================================================="
  echo " ESTADO DE APLICACION WEB / API"
  echo "======================================================="
  echo " Ruta Base             : ${APP_ROOT}"
  echo " Release Tag Instalado : ${local_tag} (Canal: ${local_ch})"
  echo " Deployment ID         : ${local_id}"
  echo " Canal Suscrito        : ${ch}"
  echo "======================================================="
}

deploy_release() {
  local tag="$1"
  local asset_url="$2"
  local prev_tag
  prev_tag="$(get_local_field releaseTag)"
  local target_dir="${RELEASES_DIR}/${tag}"

  echo "[1/4] Descargando paquete del Release ${tag}..."
  local tmp_tar="/tmp/webapp-${tag}.tar.gz"
  local auth_header=()
  if [[ -n "$GITHUB_TOKEN" ]]; then
    auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL -L "${auth_header[@]}" -H "Accept: application/octet-stream" "$asset_url" -o "$tmp_tar"

  echo "[2/4] Extrayendo en ${target_dir}..."
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  tar -xzf "$tmp_tar" -C "$target_dir"
  rm -f "$tmp_tar"

  # Vincular .env y storage persistentes sin sobrescribirlos
  if [[ -f "${APP_ROOT}/.env" ]]; then
    ln -sfn "${APP_ROOT}/.env" "${target_dir}/.env"
  fi
  if [[ -d "${APP_ROOT}/storage" ]]; then
    rm -rf "${target_dir}/storage"
    ln -sfn "${APP_ROOT}/storage" "${target_dir}/storage"
  fi

  echo "[3/4] Cambiando symlink 'current' -> ${target_dir} (Zero-Downtime)..."
  ln -sfn "$target_dir" "$CURRENT_LINK"

  echo "[4/4] Recargando servicio web..."
  eval "$RELOAD_CMD" || true

  local new_id
  new_id="$(get_local_field deploymentId)"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] DEPLOY | De: ${prev_tag} -> A: ${tag} (${new_id})" >> "$HISTORY_FILE"
  echo "Despliegue completado con exito: ${tag} (${new_id})"
}

case "$ACTION" in
  status)
    show_status
    ;;
  set-channel)
    NEW_CH="${1:-stable}"
    save_subscribed_channel "$NEW_CH"
    echo "Canal suscrito actualizado a: ${NEW_CH}"
    show_status
    ;;
  register-cron)
    NEW_CH="${1:-stable}"
    INTERVAL="${2:-15}"
    save_subscribed_channel "$NEW_CH"
    SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    CRON_LINE="*/${INTERVAL} * * * * APP_ROOT=${APP_ROOT} GITHUB_REPO=${GITHUB_REPO} ${SCRIPT_ABS} auto-update >> ${APP_ROOT}/autoupdate.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "${SCRIPT_ABS} auto-update" || true; echo "$CRON_LINE") | crontab -
    echo "Cron job registrado cada ${INTERVAL} min vigilando el canal '${NEW_CH}'."
    ;;
  rollback)
    PREV_RELEASE="$(ls -1dt "${RELEASES_DIR}"/* 2>/dev/null | sed -n '2p')"
    if [[ -z "$PREV_RELEASE" ]]; then
      echo "No hay un release anterior en ${RELEASES_DIR} para hacer rollback."
      exit 1
    fi
    ln -sfn "$PREV_RELEASE" "$CURRENT_LINK"
    eval "$RELOAD_CMD" || true
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ROLLBACK -> $(basename "$PREV_RELEASE")" >> "$HISTORY_FILE"
    echo "Rollback completado hacia: $(basename "$PREV_RELEASE")"
    show_status
    ;;
  update|auto-update)
    CH="$(get_subscribed_channel)"
    LOCAL_TAG="$(get_local_field releaseTag)"
    JSON="$(fetch_remote_release_json "$TARGET_TAG" "$CH")"
    REMOTE_TAG="$(echo "$JSON" | grep -m1 '"tag_name"' | cut -d'"' -f4)"
    ASSET_URL="$(echo "$JSON" | grep -B3 '"name": ".*\.tar\.gz"' | grep '"url"' | head -n1 | cut -d'"' -f4)"

    if [[ -z "$REMOTE_TAG" || -z "$ASSET_URL" ]]; then
      echo "No se encontro un release valido con paquete .tar.gz para canal '${CH}'."
      exit 1
    fi

    if [[ "$ACTION" == "auto-update" && "$LOCAL_TAG" == "$REMOTE_TAG" ]]; then
      echo "[AUTO-UPDATE] Sin cambios (${LOCAL_TAG} al dia en canal ${CH})."
      exit 0
    fi

    deploy_release "$REMOTE_TAG" "$ASSET_URL"
    ;;
esac
