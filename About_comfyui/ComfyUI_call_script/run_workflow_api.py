import argparse
import json
import os
import shutil
import socket
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request

try:
    import websocket
except ImportError:
    websocket = None


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run a ComfyUI API workflow using only JSON params."
    )
    parser.add_argument(
        "--params-json",
        default=None,
        help=(
            "JSON string config. Keys: workflow, output_dir, overrides, server, "
            "poll_interval, timeout, use_websocket, ws_connect_timeout, "
            "progress_callback_url, progress_callback_timeout, "
            "allow_external_image_path, comfy_input_dir, workflow_id."
        ),
    )
    parser.add_argument(
        "--params-file",
        default=None,
        help="Path to JSON config file with the same keys as --params-json.",
    )
    return parser.parse_args()


def normalize_server(server):
    return server.rstrip("/")


def load_params_config(params_json, params_file):
    if (not params_json and not params_file) or (params_json and params_file):
        raise ValueError("Provide exactly one of --params-json or --params-file.")

    if params_json:
        data = json.loads(params_json)
    else:
        with open(params_file, "r", encoding="utf-8") as f:
            data = json.load(f)

    if not isinstance(data, dict):
        raise ValueError("Params config must be a JSON object.")
    return data


def build_options_from_config(config):
    default_comfy_input_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "input")
    )
    opts = {
        "server": config.get("server", "http://127.0.0.1:8888"),
        "workflow": config.get("workflow"),
        "output_dir": (config.get("output_dir") or "./api_outputs"),
        "poll_interval": config.get("poll_interval", 0.8),
        "timeout": config.get("timeout", 600.0),
        "overrides": config.get("overrides", []),
        "use_websocket": config.get("use_websocket", True),
        "ws_connect_timeout": config.get("ws_connect_timeout", 8.0),
        "progress_callback_url": config.get("progress_callback_url"),
        "progress_callback_timeout": config.get("progress_callback_timeout", 3.0),
        "allow_external_image_path": config.get("allow_external_image_path", True),
        "comfy_input_dir": config.get("comfy_input_dir", default_comfy_input_dir),
        "workflow_id": config.get("workflow_id"),
    }
    if not opts["workflow"]:
        raise ValueError("Missing required key in params JSON: workflow")
    if not isinstance(opts["overrides"], list):
        raise ValueError("overrides in params JSON must be a list of strings.")
    return opts


def load_workflow(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    # Accept both pure prompt JSON and wrapped payload JSON.
    if isinstance(data, dict) and "prompt" in data and isinstance(data["prompt"], dict):
        workflow_meta = None
        extra_data = data.get("extra_data", {})
        if isinstance(extra_data, dict):
            extra_pnginfo = extra_data.get("extra_pnginfo", {})
            if isinstance(extra_pnginfo, dict):
                workflow_meta = extra_pnginfo.get("workflow")
        return data["prompt"], workflow_meta
    return data, None


def parse_value(raw_value):
    # Try JSON first so numbers/bool/null/arrays/objects work naturally.
    try:
        return json.loads(raw_value)
    except json.JSONDecodeError:
        return raw_value


def apply_overrides(prompt, overrides):
    for item in overrides:
        if "=" not in item:
            raise ValueError(f"Invalid override (missing '='): {item}")
        key, value = item.split("=", 1)
        if "." not in key:
            raise ValueError(f"Invalid override (missing '.'): {item}")
        node_id, input_name = key.split(".", 1)
        if node_id not in prompt:
            raise KeyError(f"Node id not found: {node_id}")
        if "inputs" not in prompt[node_id]:
            raise KeyError(f"Node {node_id} has no 'inputs' field")

        prompt[node_id]["inputs"][input_name] = parse_value(value)


def normalize_image_overrides(prompt, overrides, allow_external_image_path, comfy_input_dir):
    if not allow_external_image_path:
        return overrides

    normalized = []
    os.makedirs(comfy_input_dir, exist_ok=True)
    for item in overrides:
        if "=" not in item or "." not in item.split("=", 1)[0]:
            normalized.append(item)
            continue

        key, value = item.split("=", 1)
        node_id, input_name = key.split(".", 1)
        node = prompt.get(node_id, {})
        class_type = node.get("class_type")

        if input_name != "image" or class_type != "LoadImage":
            normalized.append(item)
            continue

        value_str = parse_value(value)
        if not isinstance(value_str, str) or not os.path.isabs(value_str):
            normalized.append(item)
            continue

        if not os.path.isfile(value_str):
            raise FileNotFoundError(f"Image file not found: {value_str}")

        src_path = value_str
        src_name = os.path.basename(src_path)
        dst_name = f"ext_{uuid.uuid4().hex[:8]}_{src_name}"
        dst_path = os.path.join(comfy_input_dir, dst_name)
        shutil.copy2(src_path, dst_path)
        print(f"[信息] 外部图片已导入ComfyUI输入目录: {src_path} -> {dst_path}")
        normalized.append(f"{node_id}.{input_name}={dst_name}")
    return normalized


def http_json(url, payload=None):
    if payload is None:
        try:
            with urllib.request.urlopen(url) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"HTTP {e.code} calling {url}. Response body: {body}"
            ) from e
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"HTTP {e.code} calling {url}. Response body: {body}"
        ) from e


def post_progress_callback(url, payload, timeout):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        # Callback response body is not used, but read once to avoid resource warning.
        resp.read()


def emit_progress(callback_url, callback_timeout, percent):
    payload = {"percent": round(float(percent), 2)}
    if callback_url:
        try:
            post_progress_callback(callback_url, payload, callback_timeout)
        except Exception as e:
            print(f"[警告] 进度回调失败: {e}")
    print(f"[进度] {json.dumps(payload, ensure_ascii=False)}")


def queue_prompt(server, prompt, client_id, callback_url, callback_timeout, workflow_id):
    payload = {
        "prompt": prompt,
        "client_id": client_id,
        "extra_data": {"extra_pnginfo": {"workflow": {"id": workflow_id}}},
    }
    print(f"[信息] 正在提交工作流到: {server}/prompt")
    print(f"[信息] 请求参数: client_id={client_id}, 节点数={len(prompt)}")
    result = http_json(f"{server}/prompt", payload=payload)
    print(f"[信息] 提交成功，任务ID: {result['prompt_id']}")
    emit_progress(callback_url, callback_timeout, 0.0)
    return result["prompt_id"]


def build_ws_url(server, client_id):
    parsed = urllib.parse.urlparse(server)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"Unsupported server scheme for websocket: {parsed.scheme}")
    ws_scheme = "wss" if parsed.scheme == "https" else "ws"
    return f"{ws_scheme}://{parsed.netloc}/ws?clientId={urllib.parse.quote(client_id)}"


def open_ws_connection(server, client_id, connect_timeout):
    if websocket is None:
        raise RuntimeError("websocket-client is not installed.")
    url = build_ws_url(server, client_id)
    print(f"[信息] 正在连接WebSocket: {url}")
    ws = websocket.create_connection(url, timeout=connect_timeout)
    ws.settimeout(1.0)
    print("[信息] WebSocket已连接")
    return ws


def wait_execution_ws(ws, prompt_id, timeout, callback_url, callback_timeout):
    deadline = time.time() + timeout
    last_heartbeat = 0.0
    last_progress_emit = 0.0
    progress_emit_interval = 0.8
    last_percent = -1.0
    print(f"[信息] WebSocket实时监听中: prompt_id={prompt_id}, 超时={timeout}秒")
    while time.time() < deadline:
        try:
            raw_msg = ws.recv()
        except websocket.WebSocketTimeoutException:
            now = time.time()
            if (now - last_heartbeat) >= 3.0:
                remaining = int(deadline - now)
                print(f"[信息] WebSocket等待事件中，预计剩余{remaining}秒")
                last_heartbeat = now
            continue
        except socket.timeout:
            continue

        if not raw_msg:
            continue

        try:
            msg = json.loads(raw_msg)
        except json.JSONDecodeError:
            continue

        msg_type = msg.get("type")
        data = msg.get("data", {}) if isinstance(msg.get("data"), dict) else {}
        msg_prompt_id = data.get("prompt_id")
        if msg_prompt_id is not None and msg_prompt_id != prompt_id:
            continue

        if msg_type == "progress":
            max_steps = data.get("max", 0) or 0
            value = data.get("value", 0) or 0
            node = data.get("node")
            percent = (float(value) / float(max_steps)) if max_steps else 0.0
            percent = min(max(percent, 0.0), 1.0)
            now = time.time()
            should_emit = (
                last_percent < 0
                or abs(percent - last_percent) >= 0.02
                or (now - last_progress_emit) >= progress_emit_interval
                or percent >= 1.0
            )
            if should_emit:
                print(f"[信息] 进度: {percent * 100:.1f}%")
                emit_progress(callback_url, callback_timeout, percent * 100.0)
                last_progress_emit = now
                last_percent = percent
        elif msg_type == "execution_success" and msg_prompt_id == prompt_id:
            print("[信息] WebSocket事件: 任务成功")
            emit_progress(callback_url, callback_timeout, 100.0)
            return
        elif msg_type == "execution_error" and msg_prompt_id == prompt_id:
            print(f"[错误] WebSocket事件: 任务失败, data={data}")
            raise RuntimeError(f"Execution failed for prompt_id={prompt_id}: {data}")
    raise TimeoutError(f"Timed out waiting websocket events for prompt_id={prompt_id}")


def wait_history(server, prompt_id, timeout, poll_interval):
    deadline = time.time() + timeout
    attempts = 0
    last_progress_log_time = 0.0
    progress_log_interval = 3.0
    print(
        f"[信息] 等待任务完成: 任务ID={prompt_id}, 超时={timeout}秒, 轮询间隔={poll_interval}秒"
    )
    while time.time() < deadline:
        attempts += 1
        history = http_json(f"{server}/history/{prompt_id}")
        if prompt_id in history:
            elapsed = int(timeout - (deadline - time.time()))
            print(f"[信息] 任务完成: 耗时约{elapsed}秒, 轮询次数={attempts}")
            return history[prompt_id]
        remaining = int(deadline - time.time())
        now = time.time()
        if attempts == 1 or (now - last_progress_log_time) >= progress_log_interval:
            print(f"[信息] 任务执行中: 已轮询{attempts}次，预计剩余{remaining}秒")
            last_progress_log_time = now
        time.sleep(poll_interval)
    raise TimeoutError(f"Timed out waiting for prompt_id={prompt_id}")


def download_image(server, image_meta):
    query = urllib.parse.urlencode(
        {
            "filename": image_meta["filename"],
            "subfolder": image_meta.get("subfolder", ""),
            "type": image_meta.get("type", "output"),
        }
    )
    with urllib.request.urlopen(f"{server}/view?{query}") as resp:
        return resp.read()


def save_history_images(server, history_item, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    saved = []

    outputs = history_item.get("outputs", {})
    print(f"[信息] 输出目录: {output_dir}")
    print(f"[信息] 输出节点: {list(outputs.keys())}")
    for node_id, node_output in outputs.items():
        images = node_output.get("images", [])
        if images:
            print(f"[信息] 节点 {node_id}: 共 {len(images)} 张图片")
        for i, image_meta in enumerate(images):
            print(
                f"[信息] 正在下载: 节点={node_id}, 第{i + 1}/{len(images)}张, 文件={image_meta.get('filename', '')}"
            )
            image_bytes = download_image(server, image_meta)
            filename = image_meta["filename"]
            # Avoid accidental overwrite if same filename appears.
            local_name = f"{node_id}_{i}_{filename}"
            local_path = os.path.join(output_dir, local_name)
            with open(local_path, "wb") as f:
                f.write(image_bytes)
            saved.append(local_path)
            print(f"[信息] 已保存: {local_path}")
    return saved


def main():
    args = parse_args()
    config = load_params_config(args.params_json, args.params_file)
    opts = build_options_from_config(config)
    server = normalize_server(opts["server"])
    print("[信息] 当前生效配置:")
    print(f"       服务地址: {server}")
    print(f"       工作流文件: {opts['workflow']}")
    print(f"       输出目录: {opts['output_dir']}")
    print(f"       覆盖项数量: {len(opts['overrides'])}")
    print(f"       超时设置: {opts['timeout']}秒, 轮询间隔: {opts['poll_interval']}秒")
    print(
        f"       WebSocket实时进度: {'开启' if opts['use_websocket'] else '关闭'}, "
        f"连接超时: {opts['ws_connect_timeout']}秒"
    )
    print(f"       进度回调地址: {opts['progress_callback_url'] or '未配置'}")
    print(
        f"       外部图片路径支持: {'开启' if opts['allow_external_image_path'] else '关闭'}, "
        f"Comfy输入目录: {opts['comfy_input_dir']}"
    )

    prompt, workflow_meta = load_workflow(opts["workflow"])
    workflow_id = opts["workflow_id"]
    if not workflow_id and isinstance(workflow_meta, dict):
        workflow_id = workflow_meta.get("id")
    if not workflow_id:
        workflow_id = f"api:{os.path.basename(opts['workflow'])}"
    print(f"       工作流标识: {workflow_id}")
    effective_overrides = normalize_image_overrides(
        prompt=prompt,
        overrides=opts["overrides"],
        allow_external_image_path=opts["allow_external_image_path"],
        comfy_input_dir=opts["comfy_input_dir"],
    )
    apply_overrides(prompt, effective_overrides)
    if opts["overrides"]:
        print("[信息] 已应用覆盖项:")
        for item in effective_overrides:
            print(f"       - {item}")

    client_id = str(uuid.uuid4())
    ws = None
    if opts["use_websocket"]:
        try:
            ws = open_ws_connection(server, client_id, opts["ws_connect_timeout"])
        except Exception as e:
            print(f"[警告] WebSocket连接失败，将仅使用history轮询: {e}")

    prompt_id = queue_prompt(
        server,
        prompt,
        client_id,
        opts["progress_callback_url"],
        opts["progress_callback_timeout"],
        workflow_id,
    )
    print(f"Queued prompt_id: {prompt_id}")

    if ws is not None:
        try:
            wait_execution_ws(
                ws=ws,
                prompt_id=prompt_id,
                timeout=opts["timeout"],
                callback_url=opts["progress_callback_url"],
                callback_timeout=opts["progress_callback_timeout"],
            )
        except Exception as e:
            print(f"[警告] WebSocket监听异常，继续使用history轮询兜底: {e}")
        finally:
            try:
                ws.close()
            except Exception:
                pass

    history_item = wait_history(
        server=server,
        prompt_id=prompt_id,
        timeout=opts["timeout"],
        poll_interval=opts["poll_interval"],
    )
    saved_files = save_history_images(server, history_item, opts["output_dir"])

    if not saved_files:
        print("Run finished, but no images found in outputs.")
        return

    print("Saved images:")
    for path in saved_files:
        print(path)


if __name__ == "__main__":
    main()
