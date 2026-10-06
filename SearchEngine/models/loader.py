import logging
import torch
from sentence_transformers import SentenceTransformer, CrossEncoder

from config import (
    EMBEDDING_MODEL_NAME, RERANKER_MODEL_NAME, EMBEDDING_DIMENSION, RERANKER_MAX_LENGTH,
    INFERENCE_BACKEND, OPENVINO_DEVICE, OPENVINO_MODEL_DIR,
    RERANKER_INSTRUCTION, RERANKER_OPENVINO_INT8, RERANKER_ENSEMBLE_MODEL, RERANKER_ENSEMBLE_WEIGHT,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Models that require trust_remote_code=True from HuggingFace Hub.
# Add any other such model IDs here so the flag is set automatically.
# ---------------------------------------------------------------------------
_TRUST_REMOTE_CODE_MODELS: set[str] = {
    "BAAI/bge-reranker-v2-minicpm-layerwise",
}

_state: dict = {
    "embedding_model": None,
    "reranker":        None,
    "device":          None,
    "loaded":          False,
}


# ─── Device detection ─────────────────────────────────────────────────────────

def _resolve_device() -> str:
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        mem  = torch.cuda.get_device_properties(0).total_memory / 1024 ** 3
        logger.info(f"GPU detected: {name} ({mem:.1f} GB) — using CUDA")
        return "cuda"
    if torch.backends.mps.is_available():
        logger.info("Apple Silicon detected — using MPS")
        return "mps"
    logger.warning("No GPU — using CPU. Expect slower inference.")
    return "cpu"


# ─── OpenVINO ─────────────────────────────────────────────────────────────────

def _use_openvino(device: str) -> bool:
    """OpenVINO is only used when configured, available, and there's no CUDA GPU."""
    if INFERENCE_BACKEND != "openvino" or device == "cuda":
        return False
    try:
        import openvino
        from optimum.intel.openvino import OVModelForFeatureExtraction  # noqa: F401
    except ImportError:
        logger.warning("INFERENCE_BACKEND='openvino' but OpenVINO/optimum-intel isn't installed — using torch.")
        return False
    devices = openvino.Core().available_devices
    if OPENVINO_DEVICE not in devices and OPENVINO_DEVICE != "AUTO":
        logger.warning(f"OpenVINO device '{OPENVINO_DEVICE}' not found (have {devices}) — using torch.")
        return False
    return True


def _load_openvino(cls, model_name: str, **kwargs):
    """
    Load `model_name` with the OpenVINO backend. The first run exports the model
    to OpenVINO IR and saves it under OPENVINO_MODEL_DIR; later runs load that copy.
    """
    local_dir = OPENVINO_MODEL_DIR / model_name.replace("/", "__")
    model_kwargs = {"device": OPENVINO_DEVICE}
    if local_dir.exists():
        logger.info(f"  Loading OpenVINO model from '{local_dir}' on {OPENVINO_DEVICE} ...")
        return cls(str(local_dir), backend="openvino", model_kwargs=model_kwargs, **kwargs)

    logger.info(f"  Exporting {model_name} to OpenVINO (one-time, may take a few minutes) ...")
    model = cls(model_name, backend="openvino", model_kwargs=model_kwargs, **kwargs)
    model.save_pretrained(str(local_dir))
    logger.info(f"  Saved OpenVINO model to '{local_dir}'.")
    return model


def is_qwen3_reranker(model_name: str) -> bool:
    return "qwen3-reranker" in model_name.lower()


# ─── Load ─────────────────────────────────────────────────────────────────────

def _load_reranker(model_name: str, device: str, use_ov: bool, dtype, needs_trust: bool):
    reranker = None
    if is_qwen3_reranker(model_name):
        from .qwen_reranker import Qwen3Reranker
        if use_ov:
            try:
                reranker = Qwen3Reranker(model_name, RERANKER_INSTRUCTION, RERANKER_MAX_LENGTH,
                                         openvino_dir=OPENVINO_MODEL_DIR, openvino_device=OPENVINO_DEVICE,
                                         openvino_int8=RERANKER_OPENVINO_INT8)
            except Exception as e:
                logger.warning(f"OpenVINO Qwen3 reranker failed ({e}) — falling back to torch.")
        if reranker is None:
            reranker = Qwen3Reranker(model_name, RERANKER_INSTRUCTION, RERANKER_MAX_LENGTH, device=device)
        logger.info(f"Reranker ready — {model_name} backend={reranker.backend}")
    elif use_ov:
        try:
            reranker = _load_openvino(
                CrossEncoder, model_name,
                max_length=RERANKER_MAX_LENGTH, trust_remote_code=needs_trust,
            )
            logger.info(f"Reranker ready — backend=openvino, device={OPENVINO_DEVICE}")
        except Exception as e:
            logger.warning(f"OpenVINO reranker failed ({e}) — falling back to torch.")
    if reranker is None:
        reranker = CrossEncoder(
            model_name,
            device=device,
            max_length=RERANKER_MAX_LENGTH,
            model_kwargs={"torch_dtype": dtype},
            trust_remote_code=needs_trust,
        )
        dname = "fp16" if device == "cuda" else "fp32"
        logger.info(f"Reranker ready — device={device}, dtype={dname}")
    return reranker


def load_models() -> None:
    if _state["loaded"]:
        logger.warning("load_models() already called — skipping.")
        return

    device = _resolve_device()
    _state["device"] = device
    use_ov = _use_openvino(device)
    if use_ov:
        logger.info(f"Using OpenVINO backend on {OPENVINO_DEVICE}.")

    # ── Embedding model ───────────────────────────────────────────────────────
    logger.info(f"Loading embedding model: {EMBEDDING_MODEL_NAME} ...")
    try:
        model = None
        if use_ov:
            try:
                model = _load_openvino(SentenceTransformer, EMBEDDING_MODEL_NAME)
            except Exception as e:
                logger.warning(f"OpenVINO embedding model failed ({e}) — falling back to torch.")
        if model is None:
            model = SentenceTransformer(EMBEDDING_MODEL_NAME, device=device)

        # Sanity-check output dimension against config
        vec = model.encode(
            "passage: test",
            normalize_embeddings=True,
            show_progress_bar=False,
        )
        if vec.shape[0] != EMBEDDING_DIMENSION:
            raise RuntimeError(
                f"Dim mismatch: expected {EMBEDDING_DIMENSION}, got {vec.shape[0]}"
            )

        _state["embedding_model"] = model
        logger.info(
            f"Embedding model ready — dim={EMBEDDING_DIMENSION}, device={device}"
        )
    except Exception as e:
        raise RuntimeError(f"Failed to load embedding model: {e}") from e

    # ── Reranker ──────────────────────────────────────────────────────────────
    # Key decisions for a 4 GB GTX 1650 Ti:
    #
    #   • Use fp16 on CUDA — halves VRAM and speeds up inference on Tensor Cores.
    #   • ms-marco-MiniLM-L-6-v2 is the recommended default: 22 M params, fits
    #     easily in 4 GB alongside the 560 MB embedding model, and reranks
    #     15 pairs in ~150 ms vs ~14 000 ms for bge-reranker-v2-m3.
    #   • bge-reranker-base (~109 M params, ~218 MB fp16) is a good middle ground
    #     if you need Arabic-aware ranking (~800 ms for 15 pairs).
    #   • bge-reranker-v2-minicpm-layerwise (~2.4 B) will OOM on 4 GB — don't use.
    #
    # trust_remote_code is set automatically for models that need it.
    logger.info(f"Loading reranker: {RERANKER_MODEL_NAME} ...")
    try:
        dtype = torch.float16 if device == "cuda" else torch.float32
        needs_trust = RERANKER_MODEL_NAME in _TRUST_REMOTE_CODE_MODELS

        if needs_trust:
            logger.warning(
                f"'{RERANKER_MODEL_NAME}' requires trust_remote_code=True — "
                f"enabling. Verify this model fits in your GPU VRAM before use."
            )

        reranker = _load_reranker(RERANKER_MODEL_NAME, device, use_ov, dtype, needs_trust)
        if RERANKER_ENSEMBLE_MODEL and RERANKER_ENSEMBLE_WEIGHT > 0:
            from .ensemble_reranker import EnsembleReranker
            second = _load_reranker(RERANKER_ENSEMBLE_MODEL, device, use_ov, dtype,
                                    RERANKER_ENSEMBLE_MODEL in _TRUST_REMOTE_CODE_MODELS)
            reranker = EnsembleReranker([(RERANKER_MODEL_NAME, reranker, 1 - RERANKER_ENSEMBLE_WEIGHT),
                                         (RERANKER_ENSEMBLE_MODEL, second, RERANKER_ENSEMBLE_WEIGHT)])
            logger.info(f"Reranker ensemble ready — {reranker.backend}")

        _state["reranker"] = reranker
    except Exception as e:
        raise RuntimeError(f"Failed to load reranker: {e}") from e

    # ── Warmup pass ───────────────────────────────────────────────────────────
    # Running one dummy inference now pays the CUDA kernel-launch overhead
    # at startup rather than on the first real user request.
    _warmup(device)

    _state["loaded"] = True
    logger.info("All models loaded and ready.")


def _warmup(device: str) -> None:
    """
    Run a single dummy forward pass through both models so CUDA kernels are
    compiled and cached before the first real request arrives.
    """
    import time
    try:
        logger.info("Running warmup inference ...")
        t0 = time.perf_counter()

        emb_model = _state["embedding_model"]
        emb_model.encode(
            "warmup query",
            normalize_embeddings=True,
            show_progress_bar=False,
        )

        reranker = _state["reranker"]
        reranker.predict(
            [["warmup query", "warmup passage"]],
            show_progress_bar=False,
            convert_to_numpy=True,
        )

        elapsed = (time.perf_counter() - t0) * 1000
        logger.info(f"Warmup complete in {elapsed:.0f} ms.")
    except Exception as e:
        # Warmup failure is non-fatal — log and continue
        logger.warning(f"Warmup inference failed (non-fatal): {e}")


# ─── Unload ───────────────────────────────────────────────────────────────────

def unload_models() -> None:
    _state["embedding_model"] = None
    _state["reranker"]        = None
    _state["loaded"]          = False
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    logger.info("Models unloaded.")


# ─── Accessors ────────────────────────────────────────────────────────────────

def get_embedding_model() -> SentenceTransformer:
    if not _state["embedding_model"]:
        raise RuntimeError("Embedding model not loaded.")
    return _state["embedding_model"]


def get_reranker() -> CrossEncoder:
    if not _state["reranker"]:
        raise RuntimeError("Reranker not loaded.")
    return _state["reranker"]


def get_device() -> str:
    return _state["device"] or "cpu"


def is_loaded() -> bool:
    return _state["loaded"]