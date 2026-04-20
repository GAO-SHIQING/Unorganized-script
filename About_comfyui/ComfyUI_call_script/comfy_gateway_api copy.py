import os
import time
import uuid
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from run_workflow_api import (
    apply_overrides,
    load_workflow,
    normalize_image_overrides,
    normalize_server,
    open_ws_connection,
    queue_prompt,
    save_history_images,
    wait_execution_ws,
    wait_history,
)


app = FastAPI(title="Comfy Gateway API", version="1.0.0")


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


@app.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


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

