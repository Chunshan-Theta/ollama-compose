#!/bin/bash

# Docker Compose 路徑
COMPOSE_FILE="./docker-compose.yml"

# 要檢查的 Container 名稱
CONTAINER_NAME="ollama-compose-ollama-1"

# GPU 檢查指令 (例如用 NVIDIA SMI)
CHECK_GPU_CMD="sudo docker exec $CONTAINER_NAME nvidia-smi"

# 執行檢查
if ! $CHECK_GPU_CMD > /dev/null 2>&1; then
  echo "$(date):$CHECK_GPU_CMD"
  echo "$(date): GPU 未啟用，正在重啟 docker-compose..."
  sudo docker compose -f $COMPOSE_FILE restart
  echo "$(date): 已重啟 docker-compose"
  #docker-compose -f $COMPOSE_FILE up -d
else
  echo "$(date): GPU 正常工作。"
fi

