#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="comfyui.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_UNIT="$SCRIPT_DIR/$SERVICE_NAME"
DST_UNIT="/etc/systemd/system/$SERVICE_NAME"

if [[ ! -f "$SRC_UNIT" ]]; then
  echo "ERROR: 未找到服务文件: $SRC_UNIT"
  exit 1
fi

echo "安装 systemd 服务: $SERVICE_NAME"
sudo cp "$SRC_UNIT" "$DST_UNIT"
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo ""
echo "安装完成。常用指令（原始）："
echo "  sudo systemctl status  $SERVICE_NAME"
echo "  sudo journalctl -u     $SERVICE_NAME -f"
echo "  sudo systemctl restart $SERVICE_NAME"
echo "  sudo systemctl stop    $SERVICE_NAME"
echo ""
echo "更省事的短命令（复制到终端执行一次即可生效）："
echo "  comfyui(){"
echo "    case \"\$1\" in"
echo "      s|status)   sudo systemctl status  $SERVICE_NAME ;;"
echo "      r|restart)  sudo systemctl restart $SERVICE_NAME ;;"
echo "      t|stop)     sudo systemctl stop    $SERVICE_NAME ;;"
echo "      l|log|logs) sudo journalctl -u     $SERVICE_NAME -f ;;"
echo "      *) echo \"用法: comfyui {status|log|restart|stop}\" ;;"
echo "    esac"
echo "  }"
echo ""
echo "然后你可以这样用："
echo "  comfyui status   # 状态"
echo "  comfyui log      # 日志"
echo "  comfyui restart  # 重启"
echo "  comfyui stop     # 停止"
