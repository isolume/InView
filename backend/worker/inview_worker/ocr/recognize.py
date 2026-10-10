"""Text recognition: OpenCV DNN CRNN-CTC (lexicon-free greedy decoding) and a Tesseract fallback."""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from functools import lru_cache
from typing import Protocol, Sequence

import cv2
import numpy as np

from .imaging import clahe, denoise, split_line

CRNN_SIZE = (100, 32)  # fixed (w, h) input of the zoo CRNN models


@dataclass
class Reading:
    text: str
    confidence: float
    engine: str        # opencv_dnn | tesseract
    model: str


class Recognizer(Protocol):
    engine: str

    def recognize(self, crop: np.ndarray) -> Reading | None: ...


def log_softmax(logits: np.ndarray) -> np.ndarray:
    shifted = logits - logits.max(axis=-1, keepdims=True)
    return shifted - np.log(np.exp(shifted).sum(axis=-1, keepdims=True))


def ctc_greedy(log_probs: np.ndarray, charset: Sequence[str]) -> tuple[str, float]:
    """Greedy CTC over (T, C) log-probabilities; class 0 is blank, classes past the charset are spaces.

    Confidence is the geometric mean of the per-step maximum probability (blanks included), so a
    single uncertain step lowers it.
    """
    best = log_probs.argmax(axis=1)
    chars, previous = [], 0
    for index in best:
        if index != 0 and index != previous:
            chars.append(charset[index - 1] if index - 1 < len(charset) else " ")
        previous = index
    confidence = float(np.exp(log_probs.max(axis=1).mean())) if len(log_probs) else 0.0
    return " ".join("".join(chars).split()), confidence


@lru_cache(maxsize=8)
def _crnn_net(path: str):
    return cv2.dnn.readNet(path)


class CrnnRecognizer:
    """One zoo CRNN model. Long lines are split into word chunks; each chunk is read on the plain and
    CLAHE-equalised crop (and rotated 180° when the plain reading is weak) and the best kept."""

    engine = "opencv_dnn"

    def __init__(self, model_path: str, charset: Sequence[str], grayscale: bool, name: str):
        self.net = _crnn_net(str(model_path))
        self.charset, self.grayscale, self.name = list(charset), grayscale, name

    def _forward(self, crop: np.ndarray) -> tuple[str, float]:
        image = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY) if self.grayscale and crop.ndim == 3 else crop
        if not self.grayscale and image.ndim == 2:
            image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
        interpolation = cv2.INTER_AREA if image.shape[0] > CRNN_SIZE[1] else cv2.INTER_CUBIC
        image = cv2.resize(image, CRNN_SIZE, interpolation=interpolation)
        # Per-channel mean: a bare 127.5 would only centre channel 0 of the colour models' input.
        self.net.setInput(cv2.dnn.blobFromImage(image, 1 / 127.5, CRNN_SIZE, (127.5, 127.5, 127.5)))
        output = np.asarray(self.net.forward())
        return ctc_greedy(log_softmax(output.reshape(output.shape[0], -1)), self.charset)

    def _best(self, chunk: np.ndarray) -> tuple[str, float]:
        candidates = [self._forward(chunk), self._forward(clahe(chunk))]
        if max(c[1] for c in candidates) < 0.6:
            candidates.append(self._forward(cv2.rotate(chunk, cv2.ROTATE_180)))
        return max(candidates, key=lambda c: (c[1], len(c[0])))

    def recognize(self, crop: np.ndarray) -> Reading | None:
        if crop.shape[0] < 48 and crop.shape[1] < 600:
            crop = denoise(crop)
        parts, confidences = [], []
        for chunk, space in split_line(crop):
            text, confidence = self._best(chunk)
            if text:
                parts.append((" " if space and parts else "") + text)
                confidences.append((confidence, max(1, len(text))))
        if not parts:
            return None
        weight = sum(n for _, n in confidences)
        confidence = sum(c * n for c, n in confidences) / weight
        return Reading("".join(parts).strip(), round(confidence, 4), self.engine, self.name)


class TesseractRecognizer:
    """Single-line Tesseract (`--psm 7`, TSV for word confidences) when the binary is installed."""

    engine = "tesseract"
    name = "tesseract"

    def __init__(self, executable: str | None = None, languages: str = "eng"):
        self.executable = executable or shutil.which("tesseract")
        self.languages = languages

    @property
    def available(self) -> bool:
        return bool(self.executable)

    def recognize(self, crop: np.ndarray) -> Reading | None:
        if not self.executable:
            return None
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY) if crop.ndim == 3 else crop
        scale = max(1.0, 48.0 / max(1, gray.shape[0]))
        gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        ok, png = cv2.imencode(".png", cv2.copyMakeBorder(gray, 8, 8, 8, 8, cv2.BORDER_REPLICATE))
        if not ok:
            return None
        try:
            output = subprocess.run([self.executable, "stdin", "stdout", "--psm", "7", "-l", self.languages, "tsv"],
                                    input=png.tobytes(), capture_output=True, timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return None
        words, confidences = [], []
        for line in output.stdout.decode(errors="ignore").splitlines()[1:]:
            fields = line.split("\t")
            if len(fields) >= 12 and fields[11].strip():
                try:
                    confidence = float(fields[10])
                except ValueError:
                    continue
                if confidence >= 0:
                    words.append(fields[11].strip())
                    confidences.append(confidence / 100.0)
        text = " ".join(words)
        if sum(c.isalnum() for c in text) < 1:
            return None
        return Reading(text, round(float(np.mean(confidences)), 4), self.engine, self.name)
