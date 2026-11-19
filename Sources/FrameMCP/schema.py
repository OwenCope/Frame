"""Read-only .frameproj validation for the Frame MCP server.

The layered .frameproj schema is owned by the sibling worker at
Sources/FrameCore/ (project_schema.json is the source of truth,
Renderer.py implements load_project/render). This module NEVER redefines
compositing or rendering -- it only loads and validates project files, and
prefers the sibling's own loader when it is importable:

    Sources/FrameCore/Renderer.py  ->  load_project(path) -> dict

The structural check below mirrors project_schema.json's required keys
(frameproj==1, screenshot.path, frame.device/color) so MCP tools can fail
with clear JSON errors instead of tracebacks when the sibling is absent.
Unknown fields are always preserved (never stripped); validation is
read-only and never writes.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

_MCP_DIR = Path(__file__).resolve().parent
_SOURCES_DIR = _MCP_DIR.parent
_FRAMECORE_DIR = _SOURCES_DIR / "FrameCore"

if _FRAMECORE_DIR.is_dir() and str(_FRAMECORE_DIR) not in sys.path:
    sys.path.insert(0, str(_FRAMECORE_DIR))

_sibling_load = None
_sibling_error = Exception
try:  # Sibling-owned loader wins when present; read-only import.
    import Renderer as _sib  # type: ignore

    if hasattr(_sib, "load_project"):
        _sibling_load = _sib.load_project
    if hasattr(_sib, "ProjectError"):
        _sibling_error = _sib.ProjectError
except Exception:
    _sibling_load = None


def _minimal_validate(doc: dict) -> list:
    """Structural check mirroring project_schema.json required keys."""
    errors = []
    if not isinstance(doc, dict):
        return ["project root must be a JSON object"]
    if doc.get("frameproj") != 1:
        errors.append("frameproj must be 1 (this reader supports v1)")
    shot = doc.get("screenshot")
    if not isinstance(shot, dict) or not shot.get("path"):
        errors.append("screenshot.path is required")
    frame = doc.get("frame")
    if not isinstance(frame, dict):
        errors.append("frame layer is required")
    else:
        if not (frame.get("device") or "").strip():
            errors.append("frame.device must be non-empty")
        if not (frame.get("color") or "").strip():
            errors.append("frame.color must be non-empty")
    bd = doc.get("backdrop", None)
    if bd is not None and not isinstance(bd, dict):
        errors.append("backdrop must be an object when present")
    for layer in ("backdrop", "adjust"):
        obj = doc.get(layer) or {}
        if isinstance(obj, dict):
            for key in ("blur", "grain", "scale", "brightness",
                        "contrast", "saturation"):
                if key in obj and not isinstance(obj[key], (int, float)):
                    errors.append(f"{layer}.{key} must be a number")
    anim = doc.get("animation") or {}
    if isinstance(anim, dict) and "preset" in anim \
            and not isinstance(anim["preset"], str):
        errors.append("animation.preset must be a string")
    return errors


def load_project(path: str | Path) -> dict:
    """Load a .frameproj file (JSON), preserving unknown fields. Read-only."""
    p = Path(path).expanduser()
    if not p.exists():
        raise ValueError(f"project not found: {p}")
    if _sibling_load is not None:
        try:
            return _sibling_load(str(p))
        except _sibling_error as e:
            raise ValueError(str(e))
        except Exception:
            pass  # fall through to local JSON load
    try:
        with p.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        raise ValueError(f"invalid .frameproj JSON in {p}: {e}")
    if not isinstance(data, dict):
        raise ValueError(f"invalid .frameproj in {p}: top level must be an object")
    return data


def validate_project(doc: dict) -> list:
    """Return a list of error strings (empty = valid). Read-only."""
    return _minimal_validate(doc)


def using_sibling_schema() -> bool:
    return _sibling_load is not None
