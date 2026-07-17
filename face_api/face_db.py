"""
Face Database - Gestión de embeddings para reconocimiento facial.

Almacena embeddings como archivos .npy + índice JSON.
Soporta múltiples muestras por persona para mayor precisión.
"""

import json
import logging
import os
from pathlib import Path

import numpy as np

logger = logging.getLogger(__name__)

DB_DIR = Path(os.environ.get("FACE_DB_DIR", "/data/faces"))
INDEX_FILE = DB_DIR / "index.json"


def _ensure_dir():
    DB_DIR.mkdir(parents=True, exist_ok=True)


def _load_index() -> dict:
    if INDEX_FILE.exists():
        with open(INDEX_FILE, "r") as f:
            return json.load(f)
    return {}


def _save_index(index: dict):
    _ensure_dir()
    with open(INDEX_FILE, "w") as f:
        json.dump(index, f, indent=2)


def add_face(name: str, embedding: np.ndarray) -> int:
    """Agrega un embedding para un nombre. Retorna cantidad total de muestras."""
    _ensure_dir()
    index = _load_index()
    name_upper = name.upper()

    if name_upper not in index:
        index[name_upper] = {"samples": []}

    sample_id = len(index[name_upper]["samples"])
    npy_file = f"{name_upper}_{sample_id}.npy"
    np.save(DB_DIR / npy_file, embedding)

    index[name_upper]["samples"].append(npy_file)
    _save_index(index)

    total = len(index[name_upper]["samples"])
    logger.info(f"Added face sample {sample_id} for {name_upper} (total: {total})")
    return total


def get_all_embeddings() -> dict[str, list[np.ndarray]]:
    """Retorna dict {nombre: [embeddings]} para todas las personas registradas."""
    index = _load_index()
    result = {}
    for name, data in index.items():
        embeddings = []
        for npy_file in data["samples"]:
            path = DB_DIR / npy_file
            if path.exists():
                embeddings.append(np.load(path))
            else:
                logger.warning(f"Missing embedding file: {path}")
        if embeddings:
            result[name] = embeddings
    return result


def list_faces() -> dict[str, int]:
    """Retorna dict {nombre: cantidad_muestras}."""
    index = _load_index()
    return {name: len(data["samples"]) for name, data in index.items()}


def delete_face(name: str) -> bool:
    """Elimina todas las muestras de un nombre. Retorna True si existía."""
    index = _load_index()
    name_upper = name.upper()

    if name_upper not in index:
        return False

    for npy_file in index[name_upper]["samples"]:
        path = DB_DIR / npy_file
        if path.exists():
            path.unlink()

    del index[name_upper]
    _save_index(index)
    logger.info(f"Deleted all samples for {name_upper}")
    return True
