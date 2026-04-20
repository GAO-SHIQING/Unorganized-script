import json
import os
import socket
import time
import uuid
from threading import Thread
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from redis import Redis

from run_workflow_api import (
    apply_overrides,
    build_ws_url,
    http_json,
    load_workflow,
    normalize_image_overrides,
    normalize_server,
    queue_prompt,
    save_history_images,
    wait_history,
    websocket,
)


app = FastAPI(title="Comfy Gateway API", version="1.0.0")
REDIS_URL = os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0")
TASK_TTL_SECONDS = int(os.getenv("TASK_TTL_SECONDS", "86400"))
redis_client = Redis.from_url(REDIS_URL, decode_responses=True)


def task_key(task_id: str) -> str:
    return f"comfy:task:{task_id}"


def init_task(task_id: str, payload: "GenerateRequest", output_dir: str) -> None:
    now = str(int(time.time()))
    data = {
        "task_id": task_id,
        "status": "queued",
        "progress": "0",
        "workflow": payload.workflow,
        "output_dir": output_dir,
        "server": payload.server,
        "request_id": payload.request_id or task_id,
        "error": "",
        "prompt_id": "",
        "saved_files": "[]",
        "workflow_id": payload.workflow_id or "",
        "created_at": now,
        "updated_at": now,
    }
    key = task_key(task_id)
    redis_client.hset(key, mapping=data)
    redis_client.expire(key, TASK_TTL_SECONDS)


def update_task(task_id: str, **kwargs: str) -> None:
    kwargs["updated_at"] = str(int(time.time()))
    key = task_key(task_id)
    redis_client.hset(key, mapping=kwargs)
    redis_client.expire(key, TASK_TTL_SECONDS)


def read_task(task_id: str) -> Dict[str, str]:
    data = redis_client.hgetall(task_key(task_id))
    if not data:
        raise HTTPException(status_code=404, detail=f"task not found: {task_id}")
    return data


class GenerateRequest(BaseModel):
    workflow: str = Field(..., description="Absolute path to workflow json.")
    output_dir: str = Field(..., description="Absolute output directory.")
    server: str = Field(default="http://127.0.0.1:8888")
    overrides: List[str] = Field(default_factory=list)
    poll_interval: float = Field(default=0.8, gt=0)
    timeout: float = Field(default=600.0, gt=0)
    use_websocket: bool = Field(default=True)
    ws_connect_timeout: float = Field(default=8.0, gt=0)
    allow_external_image_path: bool = Field(default=True)
    comfy_input_dir: Optional[str] = Field(default=None)
    workflow_id: Optional[str] = Field(default=None)
    request_id: Optional[str] = Field(default=None)


class GenerateResponse(BaseModel):
    ok: bool
    request_id: str
    prompt_id: str
    server: str
    output_dir: str
    workflow_id: str
    saved_files: List[str]
    elapsed_ms: int


class GenerateAsyncResponse(BaseModel):
    ok: bool
    task_id: str
    status: str


class TaskStatusResponse(BaseModel):
    task_id: str
    status: str
    progress: float
    request_id: str
    prompt_id: Optional[str] = None
    workflow: str
    workflow_id: Optional[str] = None
    server: str
    output_dir: str
    saved_files: List[str]
    error: Optional[str] = None
    created_at: int
    updated_at: int


@app.get("/health")
def health() -> Dict[str, str]:
    try:
        redis_client.ping()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"redis unavailable: {exc}") from exc
    return {"status": "ok"}


def wait_execution_ws_with_redis(ws, prompt_id: str, timeout: float, task_id: str) -> None:
    deadline = time.time() + timeout
    last_percent = 0.0
    while time.time() < deadline:
        try:
            raw_msg = ws.recv()
        except websocket.WebSocketTimeoutException:
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
            percent = (float(value) / float(max_steps) * 100.0) if max_steps else 0.0
            percent = min(max(percent, 0.0), 100.0)
            if percent >= last_percent:
                update_task(task_id, status="running", progress=f"{percent:.2f}")
                last_percent = percent
        elif msg_type == "execution_success" and msg_prompt_id == prompt_id:
            update_task(task_id, status="running", progress="100")
            return
        elif msg_type == "execution_error" and msg_prompt_id == prompt_id:
            raise RuntimeError(f"Execution failed for prompt_id={prompt_id}: {data}")

    raise TimeoutError(f"Timed out waiting websocket events for prompt_id={prompt_id}")


def run_generate_job(task_id: str, payload: "GenerateRequest") -> None:
    started_at = time.time()
    try:
        if not os.path.isabs(payload.workflow):
            raise ValueError("workflow must be an absolute path")
        if not os.path.isfile(payload.workflow):
            raise FileNotFoundError(f"workflow not found: {payload.workflow}")
        if not os.path.isabs(payload.output_dir):
            raise ValueError("output_dir must be an absolute path")

        server = normalize_server(payload.server)
        os.makedirs(payload.output_dir, exist_ok=True)
        update_task(task_id, status="running", progress="1", server=server)

        prompt, workflow_meta = load_workflow(payload.workflow)
        workflow_id = payload.workflow_id
        if not workflow_id and isinstance(workflow_meta, dict):
            workflow_id = workflow_meta.get("id")
        if not workflow_id:
            workflow_id = f"api:{os.path.basename(payload.workflow)}"
        update_task(task_id, workflow_id=workflow_id)

        default_comfy_input_dir = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "input")
        )
        comfy_input_dir = payload.comfy_input_dir or default_comfy_input_dir

        effective_overrides = normalize_image_overrides(
            prompt=prompt,
            overrides=payload.overrides,
            allow_external_image_path=payload.allow_external_image_path,
            comfy_input_dir=comfy_input_dir,
        )
        apply_overrides(prompt, effective_overrides)

        ws = None
        client_id = str(uuid.uuid4())
        if payload.use_websocket and websocket is not None:
            try:
                ws_url = build_ws_url(server, client_id)
                ws = websocket.create_connection(ws_url, timeout=payload.ws_connect_timeout)
                ws.settimeout(1.0)
            except Exception:
                ws = None

        try:
            prompt_id = queue_prompt(
                server=server,
                prompt=prompt,
                client_id=client_id,
                callback_url=None,
                callback_timeout=3.0,
                workflow_id=workflow_id,
            )
            update_task(task_id, prompt_id=prompt_id)

            if ws is not None:
                try:
                    wait_execution_ws_with_redis(
                        ws=ws,
                        prompt_id=prompt_id,
                        timeout=payload.timeout,
                        task_id=task_id,
                    )
                finally:
                    try:
                        ws.close()
                    except Exception:
                        pass

            history_item = wait_history(
                server=server,
                prompt_id=prompt_id,
                timeout=payload.timeout,
                poll_interval=payload.poll_interval,
            )
            saved_files = save_history_images(server, history_item, payload.output_dir)
            elapsed_ms = int((time.time() - started_at) * 1000)
            update_task(
                task_id,
                status="success",
                progress="100",
                saved_files=json.dumps(saved_files, ensure_ascii=False),
                error="",
                elapsed_ms=str(elapsed_ms),
            )
        except Exception:
            raise
    except Exception as exc:
        update_task(task_id, status="failed", error=str(exc))


@app.post("/generate", response_model=GenerateResponse)
def generate(payload: GenerateRequest) -> GenerateResponse:
    started_at = time.time()

    if not os.path.isabs(payload.workflow):
        raise HTTPException(status_code=400, detail="workflow must be an absolute path")
    if not os.path.isfile(payload.workflow):
        raise HTTPException(status_code=400, detail=f"workflow not found: {payload.workflow}")
    if not os.path.isabs(payload.output_dir):
        raise HTTPException(status_code=400, detail="output_dir must be an absolute path")

    server = normalize_server(payload.server)
    request_id = payload.request_id or str(uuid.uuid4())
    os.makedirs(payload.output_dir, exist_ok=True)

    prompt, workflow_meta = load_workflow(payload.workflow)
    workflow_id = payload.workflow_id
    if not workflow_id and isinstance(workflow_meta, dict):
        workflow_id = workflow_meta.get("id")
    if not workflow_id:
        workflow_id = f"api:{os.path.basename(payload.workflow)}"

    default_comfy_input_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "input"))
    comfy_input_dir = payload.comfy_input_dir or default_comfy_input_dir

    effective_overrides = normalize_image_overrides(
        prompt=prompt,
        overrides=payload.overrides,
        allow_external_image_path=payload.allow_external_image_path,
        comfy_input_dir=comfy_input_dir,
    )
    apply_overrides(prompt, effective_overrides)

    ws = None
    client_id = str(uuid.uuid4())
    if payload.use_websocket:
        try:
            ws = open_ws_connection(server, client_id, payload.ws_connect_timeout)
        except Exception:
            ws = None

    try:
        prompt_id = queue_prompt(
            server=server,
            prompt=prompt,
            client_id=client_id,
            callback_url=None,
            callback_timeout=3.0,
            workflow_id=workflow_id,
        )

        if ws is not None:
            try:
                wait_execution_ws(
                    ws=ws,
                    prompt_id=prompt_id,
                    timeout=payload.timeout,
                    callback_url=None,
                    callback_timeout=3.0,
                )
            except Exception:
                pass
            finally:
                try:
                    ws.close()
                except Exception:
                    pass

        history_item = wait_history(
            server=server,
            prompt_id=prompt_id,
            timeout=payload.timeout,
            poll_interval=payload.poll_interval,
        )
        saved_files = save_history_images(server, history_item, payload.output_dir)
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=f"invalid override key: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"generate failed: {exc}") from exc

    elapsed_ms = int((time.time() - started_at) * 1000)
    return GenerateResponse(
        ok=True,
        request_id=request_id,
        prompt_id=prompt_id,
        server=server,
        output_dir=payload.output_dir,
        workflow_id=workflow_id,
        saved_files=saved_files,
        elapsed_ms=elapsed_ms,
    )


@app.post("/generate_async", response_model=GenerateAsyncResponse)
def generate_async(payload: GenerateRequest) -> GenerateAsyncResponse:
    if not os.path.isabs(payload.workflow):
        raise HTTPException(status_code=400, detail="workflow must be an absolute path")
    if not os.path.isfile(payload.workflow):
        raise HTTPException(status_code=400, detail=f"workflow not found: {payload.workflow}")
    if not os.path.isabs(payload.output_dir):
        raise HTTPException(status_code=400, detail="output_dir must be an absolute path")

    task_id = str(uuid.uuid4())
    init_task(task_id, payload, payload.output_dir)
    worker = Thread(target=run_generate_job, args=(task_id, payload), daemon=True)
    worker.start()
    return GenerateAsyncResponse(ok=True, task_id=task_id, status="queued")


@app.get("/task/{task_id}", response_model=TaskStatusResponse)
def task_status(task_id: str) -> TaskStatusResponse:
    data = read_task(task_id)
    saved_files_raw = data.get("saved_files", "[]")
    try:
        saved_files = json.loads(saved_files_raw)
    except json.JSONDecodeError:
        saved_files = []
    return TaskStatusResponse(
        task_id=data.get("task_id", task_id),
        status=data.get("status", "unknown"),
        progress=float(data.get("progress", "0") or 0),
        request_id=data.get("request_id", task_id),
        prompt_id=data.get("prompt_id") or None,
        workflow=data.get("workflow", ""),
        workflow_id=data.get("workflow_id") or None,
        server=data.get("server", ""),
        output_dir=data.get("output_dir", ""),
        saved_files=saved_files,
        error=data.get("error") or None,
        created_at=int(data.get("created_at", "0") or 0),
        updated_at=int(data.get("updated_at", "0") or 0),
    )


import uvicorn
if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=18080)