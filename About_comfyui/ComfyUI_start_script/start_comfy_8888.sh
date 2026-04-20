#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFY_DIR="${COMFY_DIR:-$SCRIPT_DIR}"
COMFY_MAIN="main.py"
LISTEN_ADDR="0.0.0.0"
BASE_PORT="8888"
USE_CONDA_RUN=0
USE_CPU=0
GPU_CHOICE=""
RUN_MODE="normal"
INTERACTIVE_GPU=1
INTERACTIVE_TURBO=1
HTTP_PROXY_ADDR="http://127.0.0.1:7890"
HTTPS_PROXY_ADDR="http://127.0.0.1:7890"
NO_PROXY_ADDR="localhost,127.0.0.1,192.168.0.0/16"
DUAL_GPU_A="0"
DUAL_GPU_B="1"
OLLAMA_DIR="${OLLAMA_DIR:-/home/qc/GAOSHIQING/ollama}"
OLLAMA_API_URL="${OLLAMA_API_URL:-http://127.0.0.1:11434/api/tags}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

normalize_gpu_choice() {
    case "$1" in
        all|ALL|2) echo "2" ;;
        c|C|cpu|CPU|3) echo "3" ;;
        *) echo "$1" ;;
    esac
}

port_in_use() {
    ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q LISTEN
}

ollama_is_running() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 "$OLLAMA_API_URL" >/dev/null 2>&1
        return $?
    fi
    port_in_use "$OLLAMA_PORT"
}

check_ollama() {
    echo ""
    echo "=== Ollama 状态检查 ==="
    if ollama_is_running; then
        local pids
        pids="$(pgrep -f '[o]llama serve' | xargs 2>/dev/null)"
        if [ -n "$pids" ]; then
            echo "[OK] Ollama 已启动，接口可用: $OLLAMA_API_URL (PID: $pids)"
        else
            echo "[OK] Ollama 已启动，接口可用: $OLLAMA_API_URL"
        fi
    else
        echo "[WARN] 未检测到 Ollama 运行，依赖 Ollama 的 ComfyUI 节点可能不可用"
        echo "[INFO] Ollama 目录: $OLLAMA_DIR"
        if [ -x "$OLLAMA_DIR/ollama" ]; then
            echo "[INFO] 可手动启动: $OLLAMA_DIR/ollama serve"
        else
            echo "[INFO] 可手动启动: ollama serve"
        fi
    fi
    echo "--------------------------------"
}

usage() {
    echo "用法:"
    echo "  comfyui"
    echo "  comfyui --cpu"
    echo "  comfyui --gpu 0 --turbo"
    echo "  comfyui --dual"
    echo "  comfyui --gpu all"
    echo "  comfyui --all"
    echo "  comfyui --port 8888 --listen 0.0.0.0"
}

list_port_pids() {
    ss -ltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

resolve_ports() {
    ORIGIN_PORT="$BASE_PORT"
    while true; do
        local conflict_ports=""
        if [ "$RUN_MODE" = "turbo" ] || [ "$RUN_MODE" = "dual" ]; then
            if port_in_use "$BASE_PORT"; then
                conflict_ports="$BASE_PORT"
            fi
            if port_in_use "$((BASE_PORT+1))"; then
                if [ -n "$conflict_ports" ]; then
                    conflict_ports="$conflict_ports $((BASE_PORT+1))"
                else
                    conflict_ports="$((BASE_PORT+1))"
                fi
            fi
        else
            if port_in_use "$BASE_PORT"; then
                conflict_ports="$BASE_PORT"
            fi
        fi

        if [ -z "$conflict_ports" ]; then
            break
        fi

        local killed=0
        if [ -t 0 ]; then
            echo "⚠️  端口占用: $conflict_ports"
            local pids=""
            for p in $conflict_ports; do
                local this_pids
                this_pids="$(list_port_pids "$p")"
                if [ -n "$this_pids" ]; then
                    pids="$pids $this_pids"
                fi
            done
            pids="$(echo "$pids" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null)"
            if [ -n "$pids" ]; then
                for pid in $pids; do
                    ps -p "$pid" -o pid=,cmd= 2>/dev/null
                done
                echo " [1]   终止占用进程并继续使用当前端口"
                echo " [2]   不终止，自动尝试下一个端口 (默认)"
                read -p "请输入选项 (1/2) [默认 2]: " kill_choice
                if [ "$kill_choice" = "1" ]; then
                    kill $pids 2>/dev/null
                    sleep 1
                    killed=1
                elif [ -z "$kill_choice" ] || [ "$kill_choice" = "2" ]; then
                    :
                else
                    echo "⚠️  输入无效：$kill_choice，按默认值 2 处理（自动换端口）"
                fi
            fi
        fi

        if [ "$killed" = "0" ]; then
            BASE_PORT=$((BASE_PORT+1))
        fi
    done

    if [ "$ORIGIN_PORT" != "$BASE_PORT" ]; then
        echo "⚠️  端口被占用，自动切换到 $BASE_PORT"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cpu)
            USE_CPU=1
            GPU_CHOICE="3"
            INTERACTIVE_GPU=0
            shift
            ;;
        --all|--gpu-all)
            GPU_CHOICE="2"
            INTERACTIVE_GPU=0
            shift
            ;;
        --gpu)
            if [ -z "$2" ]; then
                echo "❌ 错误：--gpu 需要参数"
                exit 1
            fi
            GPU_CHOICE="$(normalize_gpu_choice "$2")"
            [ "$GPU_CHOICE" = "3" ] && USE_CPU=1
            INTERACTIVE_GPU=0
            shift 2
            ;;
        --turbo)
            RUN_MODE="turbo"
            INTERACTIVE_TURBO=0
            shift
            ;;
        --normal)
            RUN_MODE="normal"
            INTERACTIVE_TURBO=0
            shift
            ;;
        --dual)
            RUN_MODE="dual"
            GPU_CHOICE="2"
            INTERACTIVE_GPU=0
            INTERACTIVE_TURBO=0
            shift
            ;;
        --port)
            if [ -z "$2" ]; then
                echo "❌ 错误：--port 需要参数"
                exit 1
            fi
            BASE_PORT="$2"
            shift 2
            ;;
        --listen)
            if [ -z "$2" ]; then
                echo "❌ 错误：--listen 需要参数"
                exit 1
            fi
            LISTEN_ADDR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ 未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$CONDA_DEFAULT_ENV" ] || [ "$CONDA_DEFAULT_ENV" != "GAOSHIQING" ]; then
    echo "⚠️  警告：未激活 GAOSHIQING 环境，尝试自动激活..."

    if ! command -v conda >/dev/null 2>&1; then
        if [ -f "/home/qc/anaconda3/etc/profile.d/conda.sh" ]; then
            source "/home/qc/anaconda3/etc/profile.d/conda.sh"
        elif [ -f "$HOME/anaconda3/etc/profile.d/conda.sh" ]; then
            source "$HOME/anaconda3/etc/profile.d/conda.sh"
        elif [ -f "/opt/conda/etc/profile.d/conda.sh" ]; then
            source "/opt/conda/etc/profile.d/conda.sh"
        elif [ -f "/root/miniconda3/etc/profile.d/conda.sh" ]; then
            source "/root/miniconda3/etc/profile.d/conda.sh"
        fi
    fi

    if command -v conda >/dev/null 2>&1; then
        eval "$(conda shell.bash hook 2>/dev/null)"
        if conda activate GAOSHIQING >/dev/null 2>&1; then
            echo "✅ 环境已激活: $CONDA_DEFAULT_ENV"
        else
            echo "⚠️  conda activate 失败，改用 conda run 启动"
            USE_CONDA_RUN=1
        fi
    else
        echo "❌ 错误：未找到 conda，无法启动 GAOSHIQING 环境"
        exit 1
    fi
fi

run_comfy() {
    local args=("$@")
    if [ "$USE_CPU" = "1" ]; then
        args=(--cpu "${args[@]}")
    fi
    if [ "$USE_CONDA_RUN" = "1" ]; then
        CONDA_NO_PLUGINS=true conda run -n GAOSHIQING python "$COMFY_MAIN" "${args[@]}"
    else
        python "$COMFY_MAIN" "${args[@]}"
    fi
}

if [ ! -d "$COMFY_DIR" ]; then
    echo "❌ 错误：找不到目录 $COMFY_DIR"
    exit 1
fi
cd "$COMFY_DIR" || exit
mkdir -p "$COMFY_DIR/logs"

# 启动前设置代理，确保 Python/依赖下载等网络请求走代理。
export HTTP_PROXY="$HTTP_PROXY_ADDR"
export HTTPS_PROXY="$HTTPS_PROXY_ADDR"
export NO_PROXY="$NO_PROXY_ADDR"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
export no_proxy="$NO_PROXY"

check_ollama

echo ""
echo "=== GPU 状态 ==="
nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv
echo "--------------------------------"

if [ "$INTERACTIVE_GPU" = "1" ]; then
    echo "请选择要使用的 GPU 设备："
    echo " [0]   使用 0 号显卡 (推荐)"
    echo " [1]   使用 1 号显卡"
    echo " [2]   使用所有显卡"
    echo " [3]   CPU 模式"
    read -p "请输入选项 (0/1/2/3) [默认 0]: " GPU_CHOICE
    [ -z "$GPU_CHOICE" ] && GPU_CHOICE="0"
fi

GPU_CHOICE="$(normalize_gpu_choice "$GPU_CHOICE")"
if [ "$GPU_CHOICE" = "3" ]; then
    USE_CPU=1
fi

if [ "$GPU_CHOICE" != "0" ] && [ "$GPU_CHOICE" != "1" ] && [ "$GPU_CHOICE" != "2" ] && [ "$GPU_CHOICE" != "3" ]; then
    echo "❌ 输入无效：$GPU_CHOICE"
    echo "   请输入 0/1/2/3"
    exit 1
fi

if [ "$USE_CPU" = "1" ]; then
    RUN_MODE="normal"
elif [ "$RUN_MODE" = "dual" ]; then
    :
elif [ "$INTERACTIVE_TURBO" = "1" ]; then
    echo ""
    if [ "$GPU_CHOICE" = "2" ]; then
        echo "是否开启双卡模式 (Dual)?"
        echo "   - 实例 A 绑定 GPU $DUAL_GPU_A"
        echo "   - 实例 B 绑定 GPU $DUAL_GPU_B"
        echo "   - 端口：$BASE_PORT 和 $((BASE_PORT+1))"
        echo " [1]   开启双卡模式"
        echo " [2]   不开启，使用普通模式 (默认)"
        read -p "请输入选项 (1/2) [默认 2]: " dual_choice
        if [ "$dual_choice" = "1" ]; then
            RUN_MODE="dual"
        elif [ -z "$dual_choice" ] || [ "$dual_choice" = "2" ]; then
            RUN_MODE="normal"
        else
            echo "⚠️  输入无效：$dual_choice，按默认值 2 处理（普通模式）"
            RUN_MODE="normal"
        fi
    else
        echo "是否开启 Turbo 模式（双实例分卡）?"
        echo "   - 实例 A 使用当前选择的 GPU"
        echo "   - 实例 B 自动使用另一张 GPU"
        echo "   - 端口：$BASE_PORT 和 $((BASE_PORT+1))"
        echo " [1]   开启 Turbo 模式"
        echo " [2]   不开启，使用普通模式 (默认)"
        read -p "请输入选项 (1/2) [默认 2]: " turbo_choice
        if [ "$turbo_choice" = "1" ]; then
            RUN_MODE="turbo"
        elif [ -z "$turbo_choice" ] || [ "$turbo_choice" = "2" ]; then
            RUN_MODE="normal"
        else
            echo "⚠️  输入无效：$turbo_choice，按默认值 2 处理（普通模式）"
            RUN_MODE="normal"
        fi
    fi
fi

if [ "$RUN_MODE" = "dual" ] && [ "$GPU_CHOICE" != "2" ]; then
    echo "❌ 错误：双卡并发模式要求 GPU 选择为 all"
    echo "   请使用 --gpu all --dual，或在交互中选择 [2] 使用所有显卡"
    exit 1
fi

if [ "$RUN_MODE" = "turbo" ] && [ "$GPU_CHOICE" = "2" ]; then
    echo "❌ 错误：Turbo 模式需要指定单卡（0 或 1）作为实例 A 的显卡"
    exit 1
fi

if [ "$RUN_MODE" = "dual" ] || [ "$RUN_MODE" = "turbo" ]; then
    GPU_COUNT="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
    if [ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -lt 2 ]; then
        echo "❌ 错误：当前模式至少需要 2 张可用 GPU"
        exit 1
    fi
fi

if [ "$RUN_MODE" = "turbo" ]; then
    TURBO_GPU_A="$GPU_CHOICE"
    if [ "$GPU_CHOICE" = "0" ]; then
        TURBO_GPU_B="1"
    else
        TURBO_GPU_B="0"
    fi
fi

resolve_ports

cleanup() {
    echo ""
    echo "正在停止服务..."
    kill -- -$$ 2>/dev/null
    echo "服务已停止。"
    exit
}
trap cleanup SIGINT SIGTERM

echo ""
echo "================ 启动信息 ================"
echo "目录: $COMFY_DIR"
if [ "$USE_CPU" = "1" ]; then
    echo "设备: CPU"
else
    echo "设备: $GPU_CHOICE"
fi
echo "模式: $RUN_MODE"
echo "地址: http://$LISTEN_ADDR:$BASE_PORT"
if [ "$RUN_MODE" = "turbo" ]; then
    echo "Turbo 映射: 实例A -> GPU $TURBO_GPU_A, 实例B -> GPU $TURBO_GPU_B"
elif [ "$RUN_MODE" = "dual" ]; then
    echo "Dual 映射: 实例A -> GPU $DUAL_GPU_A, 实例B -> GPU $DUAL_GPU_B"
fi
echo "HTTP_PROXY: $HTTP_PROXY"
echo "HTTPS_PROXY: $HTTPS_PROXY"
echo "NO_PROXY: $NO_PROXY"
echo "=========================================="

if [ "$RUN_MODE" == "turbo" ]; then
    PORT1=$BASE_PORT
    PORT2=$((BASE_PORT+1))
    TS="$(date +%Y%m%d_%H%M%S)"
    LOG1="$COMFY_DIR/logs/comfyui_${PORT1}_${TS}.log"
    LOG2="$COMFY_DIR/logs/comfyui_${PORT2}_${TS}.log"

    echo "启动实例 A: 端口 $PORT1, GPU $TURBO_GPU_A"
    CUDA_VISIBLE_DEVICES="$TURBO_GPU_A" run_comfy --listen "$LISTEN_ADDR" --port "$PORT1" > "$LOG1" 2>&1 &
    echo "启动实例 B: 端口 $PORT2, GPU $TURBO_GPU_B"
    CUDA_VISIBLE_DEVICES="$TURBO_GPU_B" run_comfy --listen "$LISTEN_ADDR" --port "$PORT2" > "$LOG2" 2>&1 &
    echo ""
    echo "服务已启动，请保持此窗口打开。"
    echo "实例 A: http://$LISTEN_ADDR:$PORT1"
    echo "实例 B: http://$LISTEN_ADDR:$PORT2"
    echo "日志 A: $LOG1"
    echo "日志 B: $LOG2"
    wait
elif [ "$RUN_MODE" == "dual" ]; then
    PORT1=$BASE_PORT
    PORT2=$((BASE_PORT+1))
    TS="$(date +%Y%m%d_%H%M%S)"
    LOG1="$COMFY_DIR/logs/comfyui_${PORT1}_${TS}.log"
    LOG2="$COMFY_DIR/logs/comfyui_${PORT2}_${TS}.log"

    echo "启动实例 A: 端口 $PORT1, GPU $DUAL_GPU_A"
    CUDA_VISIBLE_DEVICES="$DUAL_GPU_A" run_comfy --listen "$LISTEN_ADDR" --port "$PORT1" > "$LOG1" 2>&1 &
    echo "启动实例 B: 端口 $PORT2, GPU $DUAL_GPU_B"
    CUDA_VISIBLE_DEVICES="$DUAL_GPU_B" run_comfy --listen "$LISTEN_ADDR" --port "$PORT2" > "$LOG2" 2>&1 &
    echo ""
    echo "双卡模式服务已启动，请保持此窗口打开。"
    echo "实例 A: http://$LISTEN_ADDR:$PORT1 (GPU $DUAL_GPU_A)"
    echo "实例 B: http://$LISTEN_ADDR:$PORT2 (GPU $DUAL_GPU_B)"
    echo "日志 A: $LOG1"
    echo "日志 B: $LOG2"
    wait
else
    if [ "$USE_CPU" = "1" ]; then
        echo "使用 CPU 模式"
        unset CUDA_VISIBLE_DEVICES
        run_comfy --listen "$LISTEN_ADDR" --port "$BASE_PORT"
    elif [ "$GPU_CHOICE" = "2" ]; then
        echo "使用所有GPU设备"
        run_comfy --listen "$LISTEN_ADDR" --port "$BASE_PORT"
    else
        echo "使用单卡: $GPU_CHOICE"
        export CUDA_VISIBLE_DEVICES="$GPU_CHOICE"
        run_comfy --listen "$LISTEN_ADDR" --port "$BASE_PORT"
    fi
fi
