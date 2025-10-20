# Ollama + Traefik + WebUI：Docker Compose 部署指南

這個專案以 Docker Compose 快速部署三個服務：
- Traefik 反向代理與自動憑證（Let's Encrypt，預設使用 Staging）
- Ollama 推理服務（可選啟用 NVIDIA GPU）
- WebUI（前端介面，透過 Traefik 綁定網域）

並內建：
- 健康檢查與相依順序啟動
- 以 Traefik 中介軟體限制 Ollama API 的來源 IP（白名單）
- 以 `entrypoint.sh` 自動拉取 `MODELS` 指定的模型
- 範例自動復原腳本 `auto-restart.sh`（偵測 GPU 不可用時重啟 Compose）

---

## 架構圖

```mermaid
flowchart TD
  subgraph Internet["🌐 使用者 / 客戶端"]
    Allowed["✅ 在白名單 IP 範圍"]
    Denied["❌ 不在白名單"]
  end

  Allowed -->|HTTP(S) :8880/:8443| Traefik["🔀 Traefik (ports 80→8880, 443→8443)"]
  Denied -->|HTTP :8880| Traefik

  Traefik -->|Host(${TRAEFIK_HOSTNAME}) + TLS + BasicAuth| Dashboard["📊 Traefik Dashboard"]
  Traefik -->|Host(${OLLAMA_HOSTNAME}) + TLS| WebUI["🖥️ WebUI"]
  Traefik -->|web (HTTP) + IP 白名單| Ollama["🤖 Ollama API :11434"]

  WebUI -->|HTTP :11434| Ollama

  classDef ok fill:#e1ffe1,stroke:#00aa00,stroke-width:2px;
  classDef warn fill:#fff4e1,stroke:#ff9900,stroke-width:2px;
  classDef danger fill:#ffe1e1,stroke:#ff6666,stroke-width:2px;
  class Traefik,Dashboard,WebUI,Ollama ok
  class Denied danger
```

---

## 專案內容對照

- `docker-compose.yml`
  - networks：`traefik-network`、`ollama-network`（皆為 external，需先建立）
  - volumes：`webui-data`、`ollama-data`、`traefik-certificates`
  - services：
    - `traefik`：
      - 對外埠：`8880:80`（HTTP）、`8443:443`（HTTPS）
      - 啟用 dashboard、metrics、ping 健康檢查
      - Let's Encrypt 解析器 `letsencrypt`（預設指向 ACME Staging）
      - 以 `TRAEFIK_HOSTNAME` + BasicAuth 保護 dashboard
    - `ollama`：
      - 透過 `entrypoint.sh` 啟動並拉取 `MODELS` 指定模型
      - 可設定 NVIDIA GPU（`deploy.resources.reservations.devices`）
  - 以中介軟體 `ollama-ipwhitelist` 限制來源 IP（`192.168.0.0/16`）
      - 目前路由走 `web`（HTTP 80）入口，不啟用 TLS（相關 TLS 標籤已備註）
    - `webui`：
      - 對 Ollama 的內部位址：`http://ollama:11434`
      - 以 `OLLAMA_HOSTNAME` 綁定到 `websecure`（HTTPS）入口

- `entrypoint.sh`
  - 啟動 `ollama serve` 後，依 `MODELS`（以逗號分隔）逐一 `ollama pull`
  - 內建簡單就緒檢查（TCP 11434）

- `auto-restart.sh`
  - 以 `nvidia-smi` 檢查容器 GPU 狀態，失敗時執行 `docker compose restart`
  - 需依實際環境調整 `COMPOSE_FILE` 與 `CONTAINER_NAME`

---

## 先決條件

- Docker 與 Docker Compose（本專案使用 `docker compose` 子指令）
- 兩個外部網路需先建立：
  - `traefik-network`
  - `ollama-network`
- 若要使用 GPU：
  - 已安裝 NVIDIA Driver 與 NVIDIA Container Toolkit
  - Docker 可存取 GPU（`--gpus` 或 compose 裝置保留）

---

## 快速開始

1) 建立外部網路（只需一次）

```bash
docker network create traefik-network
docker network create ollama-network
```

2) 建立 `.env`（與 `docker-compose.yml` 同層）

```bash
# 映像版本
WEBUI_IMAGE_TAG=
OLLAMA_IMAGE_TAG=
TRAEFIK_IMAGE_TAG=

# Ollama 模型（逗號分隔）
OLLAMA_INSTALL_MODELS=llama3.1:latest

# GPU 設定（0/1/2... 或 all；未使用 GPU 可設為 0）
OLLAMA_GPU_COUNT=0

# Traefik 基本設定
TRAEFIK_LOG_LEVEL=INFO
TRAEFIK_ACME_EMAIL=you@example.com

# Traefik Dashboard 基本驗證（htpasswd 產生的字串）
# 例如：user:$apr1$...$...
TRAEFIK_BASIC_AUTH=

# 服務網域
OLLAMA_HOSTNAME=webui.example.com
TRAEFIK_HOSTNAME=traefik.example.com
```

3) 啟動服務

```bash
docker compose up -d
```

4) 基本檢查

- Traefik 健康檢查（容器內部 ping 已啟用）
- Dashboard：瀏覽 `https://<TRAEFIK_HOSTNAME>:8443`（需 DNS/hosts 指向）
- WebUI：瀏覽 `https://<OLLAMA_HOSTNAME>:8443`
- Ollama API（預設走 HTTP 入口且有 IP 白名單）：
  - 以 `http://<你的主機或 IP>:8880/api/tags` 測試（需在白名單 IP 範圍內）

---

## 環境變數一覽（來自 docker-compose.yml）

- 影像標籤
  - `WEBUI_IMAGE_TAG`：WebUI 映像，如 `ghcr.io/open-webui/open-webui:latest`（範例）
  - `OLLAMA_IMAGE_TAG`：Ollama 映像，如 `ollama/ollama:latest`（範例）
  - `TRAEFIK_IMAGE_TAG`：Traefik 映像，如 `traefik:v3`（範例）
- Ollama
  - `OLLAMA_INSTALL_MODELS`：要安裝/更新的模型清單，逗號分隔
  - `OLLAMA_GPU_COUNT`：NVIDIA GPU 數量或 `all`
- Traefik 與憑證
  - `TRAEFIK_LOG_LEVEL`：`DEBUG`/`INFO`/`WARN`/`ERROR`
  - `TRAEFIK_ACME_EMAIL`：Let's Encrypt 註冊信箱
  - `TRAEFIK_BASIC_AUTH`：Dashboard 的 BasicAuth 使用者雜湊（`basicauth.users`）
- 路由網域
  - `OLLAMA_HOSTNAME`：WebUI 路由綁定的 Host
  - `TRAEFIK_HOSTNAME`：Dashboard 路由綁定的 Host

---

## 憑證與安全性注意事項

- 預設使用 Let's Encrypt「測試環境（Staging）」：
  - Compose 內 `traefik` 的指令含有：
    `--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory`
  - 要切換到正式環境，請「移除上述 caserver 參數」或改為正式端點（未指定時即為正式）。

- Dashboard 保護：
  - 需要 `TRAEFIK_HOSTNAME` 並啟用 TLS + BasicAuth。

- Ollama API 預設走 HTTP（`web` 入口）且啟用 IP 白名單：
  - 允許來源：`192.168.0.0/16`
  - 若要啟用 TLS 與專屬網域，請在 `ollama` 服務將下列標籤由註解改為啟用：
    - `traefik.http.routers.ollama.entrypoints=websecure`
    - `traefik.http.routers.ollama.tls=true`
    - `traefik.http.routers.ollama.tls.certresolver=letsencrypt`
    - 並依需要設定 `Host(...)` 規則與對應 DNS。

---

## GPU 支援

- Compose 已包含 `deploy.resources.reservations.devices`（driver `nvidia`、`count=${OLLAMA_GPU_COUNT}`）
- 需要：
  - 安裝 NVIDIA Driver、NVIDIA Container Toolkit
  - 以 root/具備對 Docker 的 GPU 存取權限的使用者執行
- 啟動後可在容器內確認：`nvidia-smi`

---

## 腳本說明

### entrypoint.sh（隨 Ollama 容器掛載）

- 啟動 `ollama serve` → 等待 11434 就緒 → 針對 `MODELS` 清單執行 `ollama pull`
- `MODELS` 來自 `.env` 的 `OLLAMA_INSTALL_MODELS`

### auto-restart.sh（選用）

- 功能：若偵測不到 GPU，則重啟 Compose 服務
- 需調整：
  - `COMPOSE_FILE`（指向你的 `docker-compose.yml`）
  - `CONTAINER_NAME`（你的 Ollama 容器名稱）
- 可加入 crontab 週期執行，例如每 5 分鐘：

```bash
*/5 * * * * /bin/bash /path/to/auto-restart.sh >> /var/log/ollama-auto-restart.log 2>&1
```

### basic-check.sh（自動化）

已提供 `basic-check.sh` 將本節的檢查流程自動化：

- 讀取同目錄 `.env`（若存在）以取得 `OLLAMA_HOSTNAME` / `TRAEFIK_HOSTNAME`
- 檢查 traefik/ollama/webui 服務狀態與健康
- 容器內檢查 Traefik ping
- 測試 Traefik Dashboard 與 WebUI HTTPS 路由（8443）
- 測試 Ollama API HTTP 路由（8880），並提示 IP 白名單阻擋的情況
- 可選：測試 webui 容器內部連線到 ollama

使用方式（預設以本機 127.0.0.1 測試）：

```bash
./basic-check.sh --help
./basic-check.sh --host 127.0.0.1
# 若有 Dashboard 帳密：
./basic-check.sh --host 127.0.0.1 --dashboard-user <USER> --dashboard-pass <PASS>
# 若要跳過容器內部連線檢查：
./basic-check.sh --skip-internal
```

---

## 疑難排解（Troubleshooting）

- 403 Forbidden：
  - 你的來源 IP 不在白名單（`ollama-ipwhitelist`）。請調整 `traefik` 標籤的 `sourcerange`。

- WebUI 無法連到 Ollama：
  - 確認 `webui` 環境變數 `OLLAMA_BASE_URL=http://ollama:11434` 未被覆蓋
  - 確認 `ollama` 服務健康（`ollama --version` 健康檢查應通過）

- 憑證無法簽發或瀏覽器顯示不安全：
  - 仍在使用 ACME Staging。改成正式端點後需等待重新申請或清除 `traefik-certificates` 內容再啟動。

- `external` 網路不存在：
  - 先執行 `docker network create traefik-network` 與 `docker network create ollama-network`

- GPU 未被偵測：
  - 確認主機 `nvidia-smi` 正常、Docker 可用 GPU、`OLLAMA_GPU_COUNT` 設定正確

---

## 清理與停用

```bash
docker compose down
```

若要同時移除資料卷（會刪除模型、WebUI 資料與憑證）：

```bash
docker compose down -v
```

---

## 版本提示

- 此專案包含備份檔：`docker-compose.yml.backup.20251020_085723`
- 請以目前的 `docker-compose.yml` 為主；若需回滾，可參考備份版本。

---

## 版權與來源

- Compose 檔案頂部的註解來源於公開教學（heyValdemar），本專案已依實際需求調整。
- 請依自身環境設定 `.env` 與網域、白名單範圍與安全性選項。