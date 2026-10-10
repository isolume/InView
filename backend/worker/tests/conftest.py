"""Shared fixtures. Stage tests should build on these rather than a live backend."""
import pytest

from inview_worker.synthetic import offline, package


@pytest.fixture(autouse=True)
def disable_model_downloads(monkeypatch):
    monkeypatch.setenv("INVIEW_MODEL_DOWNLOAD", "0")


@pytest.fixture(scope="session")
def synthetic_archive() -> bytes:
    """Deterministic iPhone-format package: room, door, native mesh, depth, EXIT-sign keyframe."""
    return package.build()


@pytest.fixture
def synthetic_ctx(synthetic_archive):
    """Fresh ScanContext (no products yet) backed by the synthetic package files."""
    return offline.context_from_archive(synthetic_archive)
