#!/bin/bash
#
# ComfyUI 启动脚本（支持交互与非交互）
#
# 主要启动方式：
# 1) 交互模式（默认）：运行后按提示配置端口与设备
#    bash start_comfy_8888.sh
#
# 2) 非交互布局模式（适合守护进程/自动化）
#    --layout 格式："<端口>:<设备>,<端口>:<设备>,..."
#    设备可选：0/1（单卡）、2 或 all（全部GPU）、3 或 cpu（CPU）
#    示例：
#    bash start_comfy_8888.sh --layout "8888:0,8889:1"
#    bash start_comfy_8888.sh --layout "8888:all,8890:cpu"
#    bash start_comfy_8888.sh --gpu 0 --ports "8888,8889"
#    bash start_comfy_8888.sh --gpu 0 --ports "8888,8889" --vram-limit --vram-per-instance 10000
#
# 说明：
# - --layout 下不会进入交互提问，会按配置直接启动。
# - 可与 --listen 一起使用（例如 --listen 0.0.0.0）。

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
CUSTOM_LAYOUT=0
CUSTOM_PORTS_SPEC=""

# ================= 显存限制开关（按需手改） =================
# 1 = 开启：启动前按“单卡每实例预算”做显存校验，不满足则阻止启动
# 0 = 关闭：不做该校验
ENABLE_SINGLE_GPU_VRAM_LIMIT=0
# 单卡每个实例预算显存（MiB），留空表示自动均分（按当前空闲显存计算）
SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB=""
# 每张卡额外预留显存（MiB），避免刚好卡边界导致 OOM
SINGLE_GPU_VRAM_SAFETY_MB=2048
# ==========================================================

HTTP_PROXY_ADDR="http://127.0.0.1:7890"
HTTPS_PROXY_ADDR="http://127.0.0.1:7890"
NO_PROXY_ADDR="localhost,127.0.0.1,192.168.0.0/16"
DUAL_GPU_A="0"
DUAL_GPU_B="1"
OLLAMA_DIR="${OLLAMA_DIR:-/home/qc/GAOSHIQING/ollama}"
OLLAMA_API_URL="${OLLAMA_API_URL:-http://127.0.0.1:11434/api/tags}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
SUMMARY_RETENTION_DAYS="${SUMMARY_RETENTION_DAYS:-7}"
RUN_SUMMARY_LINES=()
RUN_SUMMARY_MODE=""
RUN_SUMMARY_TS_FILE=""
RUN_SUMMARY_TS_HUMAN=""

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
    echo "  comfyui --layout \"8888:0,8889:1\""
    echo "  comfyui --gpu 0 --ports \"8888,8889\""
    echo "  comfyui --gpu 0 --ports \"8888,8889\" --vram-limit --vram-per-instance 10000 --vram-reserve 2048"
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
            echo "WARN: 端口占用: $conflict_ports"
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
                    echo "WARN: 输入无效：$kill_choice，按默认值 2 处理（自动换端口）"
                fi
            fi
        fi

        if [ "$killed" = "0" ]; then
            BASE_PORT=$((BASE_PORT+1))
        fi
    done

    if [ "$ORIGIN_PORT" != "$BASE_PORT" ]; then
        echo "WARN: 端口被占用，自动切换到 $BASE_PORT"
    fi
}

resolve_single_port() {
    local target_port="$1"
    while port_in_use "$target_port"; do
        local killed=0
        echo "WARN: 端口占用: $target_port" >&2
        local pids
        pids="$(list_port_pids "$target_port" | xargs 2>/dev/null)"
        if [ -n "$pids" ]; then
            for pid in $pids; do
                ps -p "$pid" -o pid=,cmd= 2>/dev/null >&2
            done
            if [ -t 0 ]; then
                echo " [1]   终止占用进程并继续使用当前端口" >&2
                echo " [2]   不终止，自动尝试下一个端口 (默认)" >&2
                read -p "请输入选项 (1/2) [默认 2]: " kill_choice
                if [ "$kill_choice" = "1" ]; then
                    kill $pids 2>/dev/null
                    sleep 1
                    killed=1
                fi
            fi
        fi
        if [ "$killed" = "0" ]; then
            target_port=$((target_port+1))
            echo "WARN: 自动尝试端口: $target_port" >&2
        fi
    done
    echo "$target_port"
}

prompt_instance_layout() {
    local default_port="$BASE_PORT"
    local input_port=""
    local input_gpu=""
    INSTANCE_PORTS=()
    INSTANCE_GPUS=()

    while true; do
        echo ""
        read -p "请输入要启动的端口 [默认 ${default_port}]: " input_port
        [ -z "$input_port" ] && input_port="$default_port"

        if ! [[ "$input_port" =~ ^[0-9]+$ ]] || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
            echo "ERROR: 端口无效：$input_port（范围 1-65535）"
            continue
        fi

        if [[ " ${INSTANCE_PORTS[*]} " == *" ${input_port} "* ]]; then
            echo "ERROR: 端口重复：$input_port，请重新输入"
            continue
        fi

        echo "为端口 $input_port 选择设备："
        echo " [0]   GPU 0"
        echo " [1]   GPU 1"
        echo " [2]   所有 GPU"
        echo " [3]   CPU 模式"
        read -p "请输入选项 (0/1/2/3) [默认 0]: " input_gpu
        [ -z "$input_gpu" ] && input_gpu="0"
        input_gpu="$(normalize_gpu_choice "$input_gpu")"

        if [ "$input_gpu" != "0" ] && [ "$input_gpu" != "1" ] && [ "$input_gpu" != "2" ] && [ "$input_gpu" != "3" ]; then
            echo "ERROR: 输入无效：$input_gpu，请输入 0/1/2/3"
            continue
        fi

        INSTANCE_PORTS+=("$input_port")
        INSTANCE_GPUS+=("$input_gpu")
        default_port=$((input_port+1))

        while true; do
            echo "是否继续添加下一个端口实例："
            echo " [0] 不继续（默认）"
            echo " [1] 继续添加"
            read -p "请输入选项 (0/1) [默认 0]: " add_more
            [ -z "$add_more" ] && add_more="0"
            if [ "$add_more" = "1" ]; then
                break
            elif [ "$add_more" = "0" ]; then
                break 2
            else
                echo "WARN: 输入无效：$add_more，请输入 0 或 1"
            fi
        done
    done

    CUSTOM_LAYOUT=1
    RUN_MODE="custom"
}

parse_layout_spec() {
    local raw_spec="$1"
    local cleaned_spec="${raw_spec// /}"
    local entry=""
    local port=""
    local gpu=""

    if [ -z "$cleaned_spec" ]; then
        echo "ERROR: --layout 不能为空"
        exit 1
    fi

    INSTANCE_PORTS=()
    INSTANCE_GPUS=()

    IFS=',' read -r -a layout_entries <<< "$cleaned_spec"
    for entry in "${layout_entries[@]}"; do
        if [ -z "$entry" ] || [[ "$entry" != *:* ]]; then
            echo "ERROR: --layout 条目格式错误：$entry（应为 端口:设备）"
            exit 1
        fi

        port="${entry%%:*}"
        gpu="${entry#*:}"
        gpu="$(normalize_gpu_choice "$gpu")"

        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "ERROR: --layout 端口无效：$port（范围 1-65535）"
            exit 1
        fi

        if [ "$gpu" != "0" ] && [ "$gpu" != "1" ] && [ "$gpu" != "2" ] && [ "$gpu" != "3" ]; then
            echo "ERROR: --layout 设备无效：$gpu（可用 0/1/2/3 或 all/cpu）"
            exit 1
        fi

        if [[ " ${INSTANCE_PORTS[*]} " == *" ${port} "* ]]; then
            echo "ERROR: --layout 中端口重复：$port"
            exit 1
        fi

        INSTANCE_PORTS+=("$port")
        INSTANCE_GPUS+=("$gpu")
    done

    CUSTOM_LAYOUT=1
    RUN_MODE="custom"
    INTERACTIVE_GPU=0
    INTERACTIVE_TURBO=0
}

parse_ports_spec_with_device() {
    local raw_ports="$1"
    local gpu="$2"
    local cleaned_ports="${raw_ports// /}"
    local port=""

    if [ -z "$cleaned_ports" ]; then
        echo "ERROR: --ports 不能为空"
        exit 1
    fi

    if [ "$gpu" != "0" ] && [ "$gpu" != "1" ] && [ "$gpu" != "2" ] && [ "$gpu" != "3" ]; then
        echo "ERROR: --ports 需要有效设备（0/1/2/3），请先通过 --gpu/--all/--cpu 指定设备"
        exit 1
    fi

    INSTANCE_PORTS=()
    INSTANCE_GPUS=()
    IFS=',' read -r -a ports_entries <<< "$cleaned_ports"
    for port in "${ports_entries[@]}"; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "ERROR: --ports 端口无效：$port（范围 1-65535）"
            exit 1
        fi

        if [[ " ${INSTANCE_PORTS[*]} " == *" ${port} "* ]]; then
            echo "ERROR: --ports 中端口重复：$port"
            exit 1
        fi

        INSTANCE_PORTS+=("$port")
        INSTANCE_GPUS+=("$gpu")
    done

    CUSTOM_LAYOUT=1
    RUN_MODE="custom"
    INTERACTIVE_GPU=0
    INTERACTIVE_TURBO=0
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
                echo "ERROR: --gpu 需要参数"
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
                echo "ERROR: --port 需要参数"
                exit 1
            fi
            BASE_PORT="$2"
            shift 2
            ;;
        --listen)
            if [ -z "$2" ]; then
                echo "ERROR: --listen 需要参数"
                exit 1
            fi
            LISTEN_ADDR="$2"
            shift 2
            ;;
        --layout)
            if [ -z "$2" ]; then
                echo "ERROR: --layout 需要参数，例如: --layout \"8888:0,8889:1\""
                exit 1
            fi
            parse_layout_spec "$2"
            shift 2
            ;;
        --ports)
            if [ -z "$2" ]; then
                echo "ERROR: --ports 需要参数，例如: --ports \"8888,8889\""
                exit 1
            fi
            CUSTOM_PORTS_SPEC="$2"
            shift 2
            ;;
        --vram-limit)
            ENABLE_SINGLE_GPU_VRAM_LIMIT=1
            shift
            ;;
        --no-vram-limit)
            ENABLE_SINGLE_GPU_VRAM_LIMIT=0
            shift
            ;;
        --vram-per-instance)
            if [ -z "$2" ]; then
                echo "ERROR: --vram-per-instance 需要参数（正整数 MiB）"
                exit 1
            fi
            SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB="$2"
            shift 2
            ;;
        --vram-reserve)
            if [ -z "$2" ]; then
                echo "ERROR: --vram-reserve 需要参数（非负整数 MiB）"
                exit 1
            fi
            SINGLE_GPU_VRAM_SAFETY_MB="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: 未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -n "$CUSTOM_PORTS_SPEC" ]; then
    if [ "$CUSTOM_LAYOUT" = "1" ]; then
        echo "ERROR: --ports 与 --layout 不能同时使用"
        exit 1
    fi

    GPU_CHOICE="$(normalize_gpu_choice "$GPU_CHOICE")"
    if [ -z "$GPU_CHOICE" ]; then
        GPU_CHOICE="0"
    fi
    [ "$GPU_CHOICE" = "3" ] && USE_CPU=1
    parse_ports_spec_with_device "$CUSTOM_PORTS_SPEC" "$GPU_CHOICE"
fi

if [ -z "$CONDA_DEFAULT_ENV" ] || [ "$CONDA_DEFAULT_ENV" != "GAOSHIQING" ]; then
    echo "WARN: 未激活 GAOSHIQING 环境，尝试自动激活..."

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
            echo "INFO: 环境已激活: $CONDA_DEFAULT_ENV"
        else
            echo "WARN: conda activate 失败，改用 conda run 启动"
            USE_CONDA_RUN=1
        fi
    else
        echo "ERROR: 未找到 conda，无法启动 GAOSHIQING 环境"
        exit 1
    fi
fi

run_comfy() {
    local args=("$@")
    if [ "$USE_CONDA_RUN" = "1" ]; then
        CONDA_NO_PLUGINS=true conda run -n GAOSHIQING python "$COMFY_MAIN" "${args[@]}"
    else
        python "$COMFY_MAIN" "${args[@]}"
    fi
}

device_label_from_choice() {
    case "$1" in
        3) echo "CPU" ;;
        2) echo "ALL_GPU" ;;
        *) echo "GPU $1" ;;
    esac
}

print_custom_instance_lines() {
    local prefix="$1"
    for idx in "${!INSTANCE_PORTS[@]}"; do
        local label
        label="$(device_label_from_choice "${INSTANCE_GPUS[$idx]}")"
        echo "$prefix 端口 ${INSTANCE_PORTS[$idx]} -> ${label}"
    done
}

start_instance_bg() {
    local port="$1"
    local gpu="$2"
    local log_file="$3"
    local index_label="$4"

    if [ "$gpu" = "3" ]; then
        echo "启动实例 ${index_label}: 端口 $port, CPU"
        unset CUDA_VISIBLE_DEVICES
        run_comfy --cpu --listen "$LISTEN_ADDR" --port "$port" > "$log_file" 2>&1 &
    elif [ "$gpu" = "2" ]; then
        echo "启动实例 ${index_label}: 端口 $port, 所有 GPU"
        unset CUDA_VISIBLE_DEVICES
        run_comfy --listen "$LISTEN_ADDR" --port "$port" > "$log_file" 2>&1 &
    else
        echo "启动实例 ${index_label}: 端口 $port, GPU $gpu"
        CUDA_VISIBLE_DEVICES="$gpu" run_comfy --listen "$LISTEN_ADDR" --port "$port" > "$log_file" 2>&1 &
    fi
    echo "日志: $log_file"
}

append_run_summary_line() {
    local port="$1"
    local gpu="$2"
    local log_file="$3"
    local label
    label="$(device_label_from_choice "$gpu")"
    RUN_SUMMARY_LINES+=("端口 ${port} -> ${label} | 日志: ${log_file}")
}

query_gpu_free_mem_mb() {
    local gpu_index="$1"
    nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null | awk 'NR==1{print $1}'
}

check_single_gpu_vram_limit() {
    [ "$ENABLE_SINGLE_GPU_VRAM_LIMIT" = "1" ] || return 0

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "WARN: 已开启显存限制校验，但未找到 nvidia-smi，跳过校验"
        return 0
    fi

    if [ -n "$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB" ]; then
        if ! [[ "$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB" =~ ^[0-9]+$ ]] || [ "$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB" -le 0 ]; then
            echo "ERROR: SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB 必须是正整数（MiB）或留空自动均分"
            exit 1
        fi
    fi
    if ! [[ "$SINGLE_GPU_VRAM_SAFETY_MB" =~ ^[0-9]+$ ]] || [ "$SINGLE_GPU_VRAM_SAFETY_MB" -lt 0 ]; then
        echo "ERROR: SINGLE_GPU_VRAM_SAFETY_MB 必须是非负整数（MiB）"
        exit 1
    fi

    local gpu0_count=0
    local gpu1_count=0
    local idx
    local local_gpu
    local free_mem
    local required_mem
    local per_instance_budget

    if [ "$RUN_MODE" = "custom" ]; then
        for idx in "${!INSTANCE_GPUS[@]}"; do
            local_gpu="${INSTANCE_GPUS[$idx]}"
            if [ "$local_gpu" = "0" ]; then
                gpu0_count=$((gpu0_count+1))
            elif [ "$local_gpu" = "1" ]; then
                gpu1_count=$((gpu1_count+1))
            fi
        done
    elif [ "$RUN_MODE" = "turbo" ]; then
        [ "$TURBO_GPU_A" = "0" ] && gpu0_count=$((gpu0_count+1))
        [ "$TURBO_GPU_A" = "1" ] && gpu1_count=$((gpu1_count+1))
        [ "$TURBO_GPU_B" = "0" ] && gpu0_count=$((gpu0_count+1))
        [ "$TURBO_GPU_B" = "1" ] && gpu1_count=$((gpu1_count+1))
    elif [ "$RUN_MODE" = "dual" ]; then
        [ "$DUAL_GPU_A" = "0" ] && gpu0_count=$((gpu0_count+1))
        [ "$DUAL_GPU_A" = "1" ] && gpu1_count=$((gpu1_count+1))
        [ "$DUAL_GPU_B" = "0" ] && gpu0_count=$((gpu0_count+1))
        [ "$DUAL_GPU_B" = "1" ] && gpu1_count=$((gpu1_count+1))
    else
        if [ "$USE_CPU" != "1" ] && [ "$GPU_CHOICE" != "2" ]; then
            [ "$GPU_CHOICE" = "0" ] && gpu0_count=1
            [ "$GPU_CHOICE" = "1" ] && gpu1_count=1
        fi
    fi

    if [ "$gpu0_count" -gt 0 ]; then
        free_mem="$(query_gpu_free_mem_mb 0)"
        if ! [[ "$free_mem" =~ ^[0-9]+$ ]]; then
            echo "WARN: 无法读取 GPU 0 空闲显存，跳过 GPU 0 校验"
        else
            if [ -n "$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB" ]; then
                per_instance_budget="$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB"
            else
                if [ "$free_mem" -le "$SINGLE_GPU_VRAM_SAFETY_MB" ]; then
                    echo "ERROR: GPU 0 空闲显存不足以满足安全预留 ${SINGLE_GPU_VRAM_SAFETY_MB} MiB"
                    echo "       当前空闲: ${free_mem} MiB"
                    exit 1
                fi
                per_instance_budget=$(((free_mem - SINGLE_GPU_VRAM_SAFETY_MB) / gpu0_count))
                if [ "$per_instance_budget" -le 0 ]; then
                    echo "ERROR: GPU 0 自动均分后每实例预算 <= 0 MiB，无法启动"
                    echo "       计划实例数: $gpu0_count, 当前空闲: ${free_mem} MiB, 安全预留: ${SINGLE_GPU_VRAM_SAFETY_MB} MiB"
                    exit 1
                fi
                echo "INFO: GPU 0 未设置每实例预算，自动均分为 ${per_instance_budget} MiB/实例（实例数 ${gpu0_count}）"
            fi
            required_mem=$((gpu0_count * per_instance_budget + SINGLE_GPU_VRAM_SAFETY_MB))
            if [ "$required_mem" -gt "$free_mem" ]; then
                echo "ERROR: GPU 0 显存不足（已启用限制）"
                echo "       计划实例数: $gpu0_count"
                echo "       需要 >= ${required_mem} MiB（每实例 ${per_instance_budget} + 预留 ${SINGLE_GPU_VRAM_SAFETY_MB}）"
                echo "       当前空闲: ${free_mem} MiB"
                echo "       可调整脚本常量：ENABLE_SINGLE_GPU_VRAM_LIMIT / SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB / SINGLE_GPU_VRAM_SAFETY_MB"
                exit 1
            fi
        fi
    fi

    if [ "$gpu1_count" -gt 0 ]; then
        free_mem="$(query_gpu_free_mem_mb 1)"
        if ! [[ "$free_mem" =~ ^[0-9]+$ ]]; then
            echo "WARN: 无法读取 GPU 1 空闲显存，跳过 GPU 1 校验"
        else
            if [ -n "$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB" ]; then
                per_instance_budget="$SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB"
            else
                if [ "$free_mem" -le "$SINGLE_GPU_VRAM_SAFETY_MB" ]; then
                    echo "ERROR: GPU 1 空闲显存不足以满足安全预留 ${SINGLE_GPU_VRAM_SAFETY_MB} MiB"
                    echo "       当前空闲: ${free_mem} MiB"
                    exit 1
                fi
                per_instance_budget=$(((free_mem - SINGLE_GPU_VRAM_SAFETY_MB) / gpu1_count))
                if [ "$per_instance_budget" -le 0 ]; then
                    echo "ERROR: GPU 1 自动均分后每实例预算 <= 0 MiB，无法启动"
                    echo "       计划实例数: $gpu1_count, 当前空闲: ${free_mem} MiB, 安全预留: ${SINGLE_GPU_VRAM_SAFETY_MB} MiB"
                    exit 1
                fi
                echo "INFO: GPU 1 未设置每实例预算，自动均分为 ${per_instance_budget} MiB/实例（实例数 ${gpu1_count}）"
            fi
            required_mem=$((gpu1_count * per_instance_budget + SINGLE_GPU_VRAM_SAFETY_MB))
            if [ "$required_mem" -gt "$free_mem" ]; then
                echo "ERROR: GPU 1 显存不足（已启用限制）"
                echo "       计划实例数: $gpu1_count"
                echo "       需要 >= ${required_mem} MiB（每实例 ${per_instance_budget} + 预留 ${SINGLE_GPU_VRAM_SAFETY_MB}）"
                echo "       当前空闲: ${free_mem} MiB"
                echo "       可调整脚本常量：ENABLE_SINGLE_GPU_VRAM_LIMIT / SINGLE_GPU_INSTANCE_VRAM_LIMIT_MB / SINGLE_GPU_VRAM_SAFETY_MB"
                exit 1
            fi
        fi
    fi
}

write_run_summary_file() {
    local summary_dir="$COMFY_DIR/logs/run_summaries"
    local summary_file="$summary_dir/run_summary_${RUN_SUMMARY_TS_FILE}.txt"
    local line

    mkdir -p "$summary_dir"
    find "$summary_dir" -type f -name "run_summary_*.txt" -mtime +"$SUMMARY_RETENTION_DAYS" -delete 2>/dev/null

    {
        echo "ComfyUI 启动摘要"
        echo "时间: $RUN_SUMMARY_TS_HUMAN"
        echo "模式: $RUN_SUMMARY_MODE"
        echo "监听地址: $LISTEN_ADDR"
        echo "摘要保留天数: $SUMMARY_RETENTION_DAYS"
        echo "----------------------------------------"
        for line in "${RUN_SUMMARY_LINES[@]}"; do
            echo "$line"
        done
    } > "$summary_file"

    echo "启动摘要: $summary_file"
}

start_two_instance_mode() {
    local mode="$1"
    local gpu_a="$2"
    local gpu_b="$3"
    local port1="$BASE_PORT"
    local port2=$((BASE_PORT+1))
    local ts
    local log1
    local log2

    ts="$(date +%Y%m%d_%H%M%S)"
    log1="$COMFY_DIR/logs/comfyui_${port1}_${ts}.log"
    log2="$COMFY_DIR/logs/comfyui_${port2}_${ts}.log"

    echo "启动实例 A: 端口 $port1, GPU $gpu_a"
    CUDA_VISIBLE_DEVICES="$gpu_a" run_comfy --listen "$LISTEN_ADDR" --port "$port1" > "$log1" 2>&1 &
    echo "启动实例 B: 端口 $port2, GPU $gpu_b"
    CUDA_VISIBLE_DEVICES="$gpu_b" run_comfy --listen "$LISTEN_ADDR" --port "$port2" > "$log2" 2>&1 &
    echo ""

    if [ "$mode" = "dual" ]; then
        echo "双卡模式服务已启动，请保持此窗口打开。"
        echo "实例 A: http://$LISTEN_ADDR:$port1 (GPU $gpu_a)"
        echo "实例 B: http://$LISTEN_ADDR:$port2 (GPU $gpu_b)"
    else
        echo "服务已启动，请保持此窗口打开。"
        echo "实例 A: http://$LISTEN_ADDR:$port1"
        echo "实例 B: http://$LISTEN_ADDR:$port2"
    fi
    echo "日志 A: $log1"
    echo "日志 B: $log2"
    echo "实时日志: tail -f \"$log1\" \"$log2\""
    append_run_summary_line "$port1" "$gpu_a" "$log1"
    append_run_summary_line "$port2" "$gpu_b" "$log2"
    write_run_summary_file
    wait
}

if [ ! -d "$COMFY_DIR" ]; then
    echo "ERROR: 找不到目录 $COMFY_DIR"
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

if [ "$INTERACTIVE_GPU" = "1" ] && [ "$INTERACTIVE_TURBO" = "1" ] && [ "$RUN_MODE" = "normal" ]; then
    echo "请选择启动实例布局（端口 + 设备）"
    prompt_instance_layout
else
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
    echo "ERROR: 输入无效：$GPU_CHOICE"
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
                echo "WARN: 输入无效：$dual_choice，按默认值 2 处理（普通模式）"
                RUN_MODE="normal"
            fi
        else
            echo "请选择运行模式："
            echo " [1]   单实例模式 (默认)"
            echo "       - 使用 GPU $GPU_CHOICE"
            echo "       - 端口：$BASE_PORT"
            echo " [2]   Turbo 双实例分卡"
            echo "       - 实例 A 使用 GPU $GPU_CHOICE"
            echo "       - 实例 B 自动使用另一张 GPU"
            echo "       - 端口：$BASE_PORT 和 $((BASE_PORT+1))"
            read -p "请输入选项 (1/2) [默认 1]: " mode_choice
            if [ -z "$mode_choice" ] || [ "$mode_choice" = "1" ]; then
                RUN_MODE="normal"
            elif [ "$mode_choice" = "2" ]; then
                RUN_MODE="turbo"
            else
                echo "WARN: 输入无效：$mode_choice，按默认值 1 处理（单实例）"
                RUN_MODE="normal"
            fi
        fi
    fi
fi

if [ "$RUN_MODE" = "dual" ] && [ "$GPU_CHOICE" != "2" ]; then
    echo "ERROR: 双卡并发模式要求 GPU 选择为 all"
    echo "   请使用 --gpu all --dual，或在交互中选择 [2] 使用所有显卡"
    exit 1
fi

if [ "$RUN_MODE" = "turbo" ] && [ "$GPU_CHOICE" = "2" ]; then
    echo "ERROR: Turbo 模式需要指定单卡（0 或 1）作为实例 A 的显卡"
    exit 1
fi

if [ "$RUN_MODE" = "dual" ] || [ "$RUN_MODE" = "turbo" ]; then
    GPU_COUNT="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
    if [ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -lt 2 ]; then
        echo "ERROR: 当前模式至少需要 2 张可用 GPU"
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

if [ "$RUN_MODE" = "custom" ]; then
    RESOLVED_INSTANCE_PORTS=()
    RESOLVED_INSTANCE_GPUS=()
    for idx in "${!INSTANCE_PORTS[@]}"; do
        local_port="${INSTANCE_PORTS[$idx]}"
        local_gpu="${INSTANCE_GPUS[$idx]}"
        resolved_port="$(resolve_single_port "$local_port")"
        while [[ " ${RESOLVED_INSTANCE_PORTS[*]} " == *" ${resolved_port} "* ]]; do
            resolved_port=$((resolved_port+1))
            resolved_port="$(resolve_single_port "$resolved_port")"
        done
        RESOLVED_INSTANCE_PORTS+=("$resolved_port")
        RESOLVED_INSTANCE_GPUS+=("$local_gpu")
    done
    INSTANCE_PORTS=("${RESOLVED_INSTANCE_PORTS[@]}")
    INSTANCE_GPUS=("${RESOLVED_INSTANCE_GPUS[@]}")
else
    resolve_ports
fi

cleanup() {
    echo ""
    echo "正在停止服务..."
    kill -- -$$ 2>/dev/null
    echo "服务已停止。"
    exit
}
trap cleanup SIGINT SIGTERM
RUN_SUMMARY_TS_FILE="$(date +%Y%m%d_%H%M%S)"
RUN_SUMMARY_TS_HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"
check_single_gpu_vram_limit

echo ""
echo "================ 启动信息 ================"
echo "目录: $COMFY_DIR"
if [ "$RUN_MODE" = "custom" ]; then
    echo "模式: 自定义多端口"
    for idx in "${!INSTANCE_PORTS[@]}"; do
        label="$(device_label_from_choice "${INSTANCE_GPUS[$idx]}")"
        echo "实例 $((idx+1)): http://$LISTEN_ADDR:${INSTANCE_PORTS[$idx]} -> ${label}"
    done
elif [ "$USE_CPU" = "1" ]; then
    echo "设备: CPU"
else
    echo "设备: $GPU_CHOICE"
fi
if [ "$RUN_MODE" != "custom" ]; then
    echo "模式: $RUN_MODE"
    echo "地址: http://$LISTEN_ADDR:$BASE_PORT"
fi
if [ "$RUN_MODE" = "turbo" ]; then
    echo "Turbo 映射: 实例A -> GPU $TURBO_GPU_A, 实例B -> GPU $TURBO_GPU_B"
elif [ "$RUN_MODE" = "dual" ]; then
    echo "Dual 映射: 实例A -> GPU $DUAL_GPU_A, 实例B -> GPU $DUAL_GPU_B"
fi
echo "HTTP_PROXY: $HTTP_PROXY"
echo "HTTPS_PROXY: $HTTPS_PROXY"
echo "NO_PROXY: $NO_PROXY"
echo "=========================================="

if [ -t 0 ]; then
    echo ""
    echo "请确认将要启动的实例："
    if [ "$RUN_MODE" = "custom" ]; then
        print_custom_instance_lines " -"
    elif [ "$RUN_MODE" = "turbo" ]; then
        echo " - 端口 $BASE_PORT -> GPU $TURBO_GPU_A"
        echo " - 端口 $((BASE_PORT+1)) -> GPU $TURBO_GPU_B"
    elif [ "$RUN_MODE" = "dual" ]; then
        echo " - 端口 $BASE_PORT -> GPU $DUAL_GPU_A"
        echo " - 端口 $((BASE_PORT+1)) -> GPU $DUAL_GPU_B"
    elif [ "$USE_CPU" = "1" ]; then
        echo " - 端口 $BASE_PORT -> CPU"
    elif [ "$GPU_CHOICE" = "2" ]; then
        echo " - 端口 $BASE_PORT -> ALL_GPU"
    else
        echo " - 端口 $BASE_PORT -> GPU $GPU_CHOICE"
    fi
    read -p "确认启动以上实例? (Y/n) [默认 Y]: " start_confirm
    [ -z "$start_confirm" ] && start_confirm="y"
    if [ "$start_confirm" != "y" ] && [ "$start_confirm" != "Y" ]; then
        echo "已取消启动。"
        exit 0
    fi
fi

if [ "$RUN_MODE" == "custom" ]; then
    RUN_SUMMARY_MODE="custom"
    TS="$(date +%Y%m%d_%H%M%S)"
    CUSTOM_LOG_FILES=()
    echo "按自定义布局启动实例..."
    for idx in "${!INSTANCE_PORTS[@]}"; do
        port="${INSTANCE_PORTS[$idx]}"
        gpu="${INSTANCE_GPUS[$idx]}"
        log_file="$COMFY_DIR/logs/comfyui_${port}_${TS}.log"
        start_instance_bg "$port" "$gpu" "$log_file" "$((idx+1))"
        append_run_summary_line "$port" "$gpu" "$log_file"
        CUSTOM_LOG_FILES+=("$log_file")
    done
    echo ""
    echo "服务已启动，请保持此窗口打开。"
    for idx in "${!INSTANCE_PORTS[@]}"; do
        echo "端口 ${INSTANCE_PORTS[$idx]} 实时日志: tail -f \"${CUSTOM_LOG_FILES[$idx]}\""
    done
    all_logs_cmd="tail -f"
    for f in "${CUSTOM_LOG_FILES[@]}"; do
        all_logs_cmd="$all_logs_cmd \"$f\""
    done
    echo "全部实例实时日志: $all_logs_cmd"
    write_run_summary_file
    wait
elif [ "$RUN_MODE" == "turbo" ]; then
    RUN_SUMMARY_MODE="turbo"
    start_two_instance_mode "turbo" "$TURBO_GPU_A" "$TURBO_GPU_B"
elif [ "$RUN_MODE" == "dual" ]; then
    RUN_SUMMARY_MODE="dual"
    start_two_instance_mode "dual" "$DUAL_GPU_A" "$DUAL_GPU_B"
else
    RUN_SUMMARY_MODE="normal"
    if [ "$USE_CPU" = "1" ]; then
        echo "使用 CPU 模式"
        RUN_SUMMARY_LINES=("端口 ${BASE_PORT} -> CPU | 日志: 当前终端标准输出")
        write_run_summary_file
        unset CUDA_VISIBLE_DEVICES
        run_comfy --cpu --listen "$LISTEN_ADDR" --port "$BASE_PORT"
    elif [ "$GPU_CHOICE" = "2" ]; then
        echo "使用所有GPU设备"
        RUN_SUMMARY_LINES=("端口 ${BASE_PORT} -> ALL_GPU | 日志: 当前终端标准输出")
        write_run_summary_file
        run_comfy --listen "$LISTEN_ADDR" --port "$BASE_PORT"
    else
        echo "使用单卡: $GPU_CHOICE"
        RUN_SUMMARY_LINES=("端口 ${BASE_PORT} -> GPU ${GPU_CHOICE} | 日志: 当前终端标准输出")
        write_run_summary_file
        export CUDA_VISIBLE_DEVICES="$GPU_CHOICE"
        run_comfy --listen "$LISTEN_ADDR" --port "$BASE_PORT"
    fi
fi
