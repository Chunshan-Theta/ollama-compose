#!/usr/bin/env bash
# Ensure running under bash even if invoked as 'sh'
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail

# basic-check.sh
# 自動化執行 README 中的「基本檢查」：
# - 檢查 docker compose 服務是否啟動且健康（traefik/ollama/webui）
# - 檢查 Traefik ping 端點（容器內）
# - 檢查 Traefik Dashboard 路由（8443，需要 Host header，未提供帳密預期 401）
# - 檢查 WebUI HTTPS 路由（8443）
# - 檢查 Ollama API HTTP 路由（8880），考慮 IP 白名單 403 狀況
# - 選擇性：檢查 webui 容器內部是否可連到 ollama
#
# 用法：
#   ./basic-check.sh [--host 127.0.0.1] [--dashboard-user USER] [--dashboard-pass PASS] [--skip-internal] [--use-sudo]
#
# 參數：
#   --host            測試時使用的外部主機/IP（對應 compose 映射的 8880/8443），預設 127.0.0.1
#   --dashboard-user  Traefik Dashboard 的 BasicAuth 使用者（可省略，無提供帳密視 401 為可接受）
#   --dashboard-pass  Traefik Dashboard 的 BasicAuth 密碼
#   --skip-internal   跳過 "webui 容器內部連到 ollama" 測試
#   --use-sudo        使用 sudo 執行所有 docker 指令（權限不足時可用）
#
# 注意：
# - 腳本會自動讀取同目錄下 .env（若存在），載入 OLLAMA_HOSTNAME 與 TRAEFIK_HOSTNAME。
# - 需要已啟動 docker compose 服務。

TARGET_HOST="127.0.0.1"
DASH_USER=""
DASH_PASS=""
SKIP_INTERNAL="false"
USE_SUDO="false"

# 顏色/標記
ok()   { echo -e "[OK]    $*"; }
warn() { echo -e "[WARN]  $*"; }
err()  { echo -e "[ERROR] $*"; }
info() { echo -e "[INFO]  $*"; }

# 載入 .env（如存在）
if [[ -f ./.env ]]; then
  info "讀取 ./.env"
  set -a
  # shellcheck source=/dev/null
  source ./.env || true
  set +a
fi

OLLAMA_HOSTNAME="${OLLAMA_HOSTNAME:-}"
TRAEFIK_HOSTNAME="${TRAEFIK_HOSTNAME:-}"

# 參數解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      TARGET_HOST="$2"; shift 2 ;;
    --dashboard-user)
      DASH_USER="$2"; shift 2 ;;
    --dashboard-pass)
      DASH_PASS="$2"; shift 2 ;;
    --skip-internal)
      SKIP_INTERNAL="true"; shift 1 ;;
    --use-sudo)
      USE_SUDO="true"; shift 1 ;;
    -h|--help)
      echo "Usage: $0 [--host 127.0.0.1] [--dashboard-user USER] [--dashboard-pass PASS] [--skip-internal] [--use-sudo]";
      exit 0 ;;
    *)
      err "Unknown argument: $1"; exit 2 ;;
  esac
done

# Docker / Compose 指令設定與權限處理
DOCKER_BIN="docker"
DC_STYLE="compose"  # compose 或 standalone(docker-compose)

if docker compose version >/dev/null 2>&1; then
  DC_STYLE="compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_STYLE="standalone"
else
  err "找不到 docker compose 或 docker-compose 指令"; exit 1
fi

ensure_docker_access() {
  # 先依照旗標決定是否用 sudo 試一次
  if [[ "${USE_SUDO}" == "true" ]]; then
    if sudo ${DOCKER_BIN} info >/dev/null 2>&1; then
      return 0
    fi
  else
    if ${DOCKER_BIN} info >/dev/null 2>&1; then
      return 0
    fi
  fi
  # 不行就嘗試 sudo
  if sudo ${DOCKER_BIN} info >/dev/null 2>&1; then
    USE_SUDO="true"
    warn "偵測到 Docker 權限不足，將改用 sudo 執行。可改用 --use-sudo，或將使用者加入 docker 群組後重新登入。"
    return 0
  fi
  err "無法連線到 Docker daemon（可能是權限或 Docker 未啟動）。請啟動 Docker、以 sudo 執行，或加入 docker 群組。"
  return 1
}

dkr() {
  if [[ "${USE_SUDO}" == "true" ]]; then
    sudo ${DOCKER_BIN} "$@"
  else
    ${DOCKER_BIN} "$@"
  fi
}

dc() {
  if [[ "${DC_STYLE}" == "compose" ]]; then
    if [[ "${USE_SUDO}" == "true" ]]; then
      sudo ${DOCKER_BIN} compose "$@"
    else
      ${DOCKER_BIN} compose "$@"
    fi
  else
    if [[ "${USE_SUDO}" == "true" ]]; then
      sudo docker-compose "$@"
    else
      docker-compose "$@"
    fi
  fi
}

# 取得容器 ID
get_cid() {
  local svc="$1"
  dc ps -q "$svc" 2>/dev/null || true
}

# 檢查服務運行與健康
check_service() {
  local svc="$1"
  local cid
  cid=$(get_cid "$svc")
  if [[ -z "$cid" ]]; then
    err "service=$svc 未啟動（無容器）"
    return 1
  fi
  local st
  st=$(dkr inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
  local health
  health=$(dkr inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "unknown")

  if [[ "$st" == "running" ]]; then
    if [[ "$health" == "healthy" || "$health" == "none" ]]; then
      ok "service=$svc running (health=$health)"
      return 0
    else
      warn "service=$svc running (health=$health)"
      return 0
    fi
  else
    err "service=$svc 狀態=$st"
    return 1
  fi
}

# Traefik ping（容器內 8082）
check_traefik_ping() {
  local cid
  cid=$(get_cid traefik)
  if [[ -z "$cid" ]]; then
    warn "找不到 traefik 容器，略過 ping 檢查"
    return 0
  fi
  if dkr exec "$cid" sh -lc "curl -sf http://localhost:8082/ping >/dev/null 2>&1 || wget -q --spider http://localhost:8082/ping"; then
    ok "Traefik ping 通過"
  else
    err "Traefik ping 失敗"
    return 1
  fi
}

# 取 HTTP 狀態碼
http_code() {
  local url="$1"; shift
  curl -k -s -o /dev/null -w "%{http_code}" "$url" "$@"
}

# 檢查 Traefik dashboard 路由（需 Host header；無帳密時 401 亦視為路由正常）
check_dashboard_route() {
  if [[ -z "$TRAEFIK_HOSTNAME" ]]; then
    warn "未設定 TRAEFIK_HOSTNAME，略過 dashboard 路由檢查"
    return 0
  fi
  local url="https://${TARGET_HOST}:8443/api/rawdata"
  local code
  if [[ -n "$DASH_USER" && -n "$DASH_PASS" ]]; then
    code=$(http_code "$url" -H "Host: ${TRAEFIK_HOSTNAME}" -u "${DASH_USER}:${DASH_PASS}")
  else
    code=$(http_code "$url" -H "Host: ${TRAEFIK_HOSTNAME}")
  fi
  case "$code" in
    200)
      ok "Dashboard 路由可用 (200)"
      ;;
    401)
      ok "Dashboard 路由可用，但需要 BasicAuth (401 預期)"
      ;;
    3*)
      ok "Dashboard 路由回應 $code"
      ;;
    *)
      err "Dashboard 路由異常，回應 $code"
      return 1
      ;;
  esac
}

# 檢查 WebUI HTTPS 路由
check_webui_https() {
  if [[ -z "$OLLAMA_HOSTNAME" ]]; then
    warn "未設定 OLLAMA_HOSTNAME，略過 WebUI 路由檢查"
    return 0
  fi
  local url="https://${TARGET_HOST}:8443/"
  local code
  code=$(http_code "$url" -H "Host: ${OLLAMA_HOSTNAME}")
  case "$code" in
    2*|3*)
      ok "WebUI HTTPS 可用 (code=$code)"
      ;;
    *)
      err "WebUI HTTPS 異常 (code=$code)"
      return 1
      ;;
  esac
}

# 檢查 Ollama API HTTP 路由（考慮 IP 白名單）
check_ollama_http() {
  local url="http://${TARGET_HOST}:8880/api/tags"
  local code
  code=$(http_code "$url")
  case "$code" in
    2*|3*)
      ok "Ollama API HTTP 可用 (code=$code)"
      ;;
    403)
      warn "Ollama API 回應 403（可能被 IP 白名單阻擋）。確認來源 IP 是否在白名單內。"
      ;;
    *)
      err "Ollama API HTTP 異常 (code=$code)"
      return 1
      ;;
  esac
}

# 檢查 webui 容器內是否可連到 ollama
check_internal_webui_to_ollama() {
  local wcid
  wcid=$(get_cid webui)
  if [[ -z "$wcid" ]]; then
    warn "找不到 webui 容器，略過內部連線檢查"
    return 0
  fi
  if dkr exec "$wcid" sh -lc 'command -v curl >/dev/null 2>&1 && curl -sf http://ollama:11434/api/tags >/dev/null 2>&1 || (command -v wget >/dev/null 2>&1 && wget -qO- http://ollama:11434/api/tags >/dev/null 2>&1)'; then
    ok "webui 容器內可連到 ollama:11434"
  else
    err "webui 容器內無法連到 ollama:11434"
    return 1
  fi
}

main() {
  info "使用主機: ${TARGET_HOST}"
  if [[ -n "${TRAEFIK_HOSTNAME}" ]]; then info "TRAEFIK_HOSTNAME=${TRAEFIK_HOSTNAME}"; fi
  if [[ -n "${OLLAMA_HOSTNAME}" ]]; then info "OLLAMA_HOSTNAME=${OLLAMA_HOSTNAME}"; fi

  # 先確認 Docker 可用，必要時切換到 sudo
  ensure_docker_access || exit 1

  local failed=0

  check_service traefik || failed=$((failed+1))
  check_service ollama  || failed=$((failed+1))
  check_service webui   || failed=$((failed+1))

  check_traefik_ping    || failed=$((failed+1))
  check_dashboard_route || failed=$((failed+1))
  check_webui_https     || failed=$((failed+1))
  check_ollama_http     || failed=$((failed+1))

  if [[ "$SKIP_INTERNAL" != "true" ]]; then
    check_internal_webui_to_ollama || failed=$((failed+1))
  else
    info "已跳過內部連線檢查 (--skip-internal)"
  fi

  if [[ $failed -eq 0 ]]; then
    ok "所有基本檢查完成"
  else
    err "基本檢查有 $failed 項失敗"
    exit 1
  fi
}

main "$@"
