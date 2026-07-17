#!/usr/bin/env python3
"""
Face Recognition API - InsightFace + FastAPI

Servicio remoto de reconocimiento facial usando InsightFace buffalo_l (ArcFace R100).
Diseñado para correr en servidor Proxmox con CPU Xeon (sin GPU).

Endpoints:
  POST /recognize     - Recibe imagen JPEG, detecta y reconoce rostros
  POST /train/{name}  - Registra un rostro con nombre
  GET  /faces         - Lista rostros entrenados
  DELETE /faces/{name} - Elimina rostro
  GET  /health        - Health check
"""

import io
import logging
import os
import time

import cv2
import insightface
import numpy as np
from fastapi import Depends, FastAPI, File, HTTPException, UploadFile
from fastapi.security import APIKeyHeader
from insightface.app import FaceAnalysis
from PIL import Image

import face_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

RECOGNITION_THRESHOLD = float(os.environ.get("RECOGNITION_THRESHOLD", "0.45"))
DETECTION_THRESHOLD = float(os.environ.get("DETECTION_THRESHOLD", "0.5"))
MODEL_NAME = os.environ.get("MODEL_NAME", "buffalo_l")
API_KEY = os.environ.get("FACE_API_KEY", "")

app = FastAPI(title="Face Recognition API", version="1.0.0")
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(key: str = Depends(api_key_header)):
    """Verifica API key si está configurada (FACE_API_KEY env var)."""
    if not API_KEY:
        return  # Sin key configurada, acceso libre (backward compatible)
    if key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")

face_app: FaceAnalysis = None
known_embeddings: dict[str, list[np.ndarray]] = {}


def load_model():
    global face_app
    logger.info(f"Loading InsightFace model '{MODEL_NAME}' (CPU)...")
    t0 = time.time()
    face_app = FaceAnalysis(
        name=MODEL_NAME,
        providers=["CPUExecutionProvider"],
    )
    face_app.prepare(ctx_id=0, det_size=(640, 640), det_thresh=DETECTION_THRESHOLD)
    elapsed = time.time() - t0
    logger.info(f"Model loaded in {elapsed:.1f}s")


def reload_embeddings():
    global known_embeddings
    known_embeddings = face_db.get_all_embeddings()
    total = sum(len(v) for v in known_embeddings.values())
    logger.info(f"Loaded {total} embeddings for {len(known_embeddings)} people")


def compare_embedding(embedding: np.ndarray) -> tuple[str, float]:
    """Compara un embedding contra la base de datos. Retorna (nombre, confianza)."""
    best_name = "unknown"
    best_score = 0.0

    for name, embeddings_list in known_embeddings.items():
        for known_emb in embeddings_list:
            # Similitud coseno
            score = float(np.dot(embedding, known_emb) / (
                np.linalg.norm(embedding) * np.linalg.norm(known_emb)
            ))
            if score > best_score:
                best_score = score
                best_name = name

    if best_score < RECOGNITION_THRESHOLD:
        return "unknown", best_score

    return best_name, best_score


def decode_image(data: bytes) -> np.ndarray:
    """Decodifica bytes de imagen a numpy array BGR (formato OpenCV)."""
    img = Image.open(io.BytesIO(data))
    img = img.convert("RGB")
    return cv2.cvtColor(np.array(img), cv2.COLOR_RGB2BGR)


@app.on_event("startup")
async def startup():
    load_model()
    reload_embeddings()


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "faces_registered": len(known_embeddings),
        "threshold": RECOGNITION_THRESHOLD,
    }


@app.post("/recognize")
async def recognize(file: UploadFile = File(...), _=Depends(verify_api_key)):
    """Recibe imagen, detecta rostros y los compara contra la base de datos."""
    t0 = time.time()

    data = await file.read()
    if len(data) == 0:
        raise HTTPException(status_code=400, detail="Empty file")

    img = decode_image(data)
    faces = face_app.get(img)

    results = []
    for face in faces:
        bbox = face.bbox.astype(int).tolist()
        embedding = face.embedding

        name, confidence = compare_embedding(embedding)
        results.append({
            "name": name,
            "confidence": round(confidence, 4),
            "bbox": bbox,
        })

    elapsed_ms = (time.time() - t0) * 1000
    logger.info(
        f"Recognized {len(faces)} face(s) in {elapsed_ms:.0f}ms: "
        f"{[r['name'] for r in results]}"
    )

    return {
        "faces": results,
        "processing_ms": round(elapsed_ms, 1),
    }


@app.post("/train/{name}")
async def train(name: str, file: UploadFile = File(...), _=Depends(verify_api_key)):
    """Registra un rostro. Enviar imagen con exactamente 1 rostro visible."""
    data = await file.read()
    if len(data) == 0:
        raise HTTPException(status_code=400, detail="Empty file")

    img = decode_image(data)
    faces = face_app.get(img)

    if len(faces) == 0:
        raise HTTPException(status_code=400, detail="No face detected in image")
    if len(faces) > 1:
        raise HTTPException(
            status_code=400,
            detail=f"Expected 1 face, found {len(faces)}. Use image with single face.",
        )

    embedding = faces[0].embedding
    total = face_db.add_face(name, embedding)
    reload_embeddings()

    return {
        "name": name.upper(),
        "samples": total,
        "message": f"Face registered for {name.upper()} ({total} sample(s))",
    }


@app.get("/faces")
async def list_faces():
    """Lista todos los rostros registrados y cantidad de muestras."""
    return {"faces": face_db.list_faces()}


@app.delete("/faces/{name}")
async def delete_face(name: str, _=Depends(verify_api_key)):
    """Elimina todas las muestras de un nombre."""
    if not face_db.delete_face(name):
        raise HTTPException(status_code=404, detail=f"Face '{name}' not found")

    reload_embeddings()
    return {"message": f"Deleted all samples for {name.upper()}"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=5050)
