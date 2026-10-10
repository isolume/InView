"""Stage: OCR of every RGB frame (OpenCV DNN, Tesseract fallback) fused with Apple Vision, placed in 3D."""
from __future__ import annotations

from .. import ocr
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class TextStage(Stage):
    name = "text"
    provides = (ProductName.TEXT,)

    def run(self, ctx) -> StageResult:
        options = ctx.config.get("ocr") or {}
        store = ocr.ModelStore(options.get("model_dir"), options.get("download"))
        engine = ocr.OcrEngine.build(store, ocr.OcrConfig.from_dict(options))
        results, summary, notices = ocr.analyze(ctx.inputs.frames, ctx.manifest(), ctx.image, ctx.asset, engine,
                                                ctx.inputs.camera_positions)
        return StageResult({ProductName.TEXT: Product(results)}, summary, notices)
