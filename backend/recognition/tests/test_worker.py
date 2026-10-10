"""Run with Python's unittest; mask/protocol tests do not import Torch."""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import core
import worker


def request(request_id="frame-1", **overrides):
    value = {"request_id": request_id, "color_jpeg": base64.b64encode(b"fixture").decode(),
             "depth_width": 7, "depth_height": 7}
    value.update(overrides)
    return value


class SamplingTests(unittest.TestCase):
    def test_native_non_square_pixel_centers_are_used(self):
        mask = [[0 for _ in range(10)] for _ in range(14)]
        for y in [5, 7, 9]:
            for x in [3, 5, 7]:
                mask[y][x] = 1
        self.assertEqual(core.sample_depth_indices(mask, 5, 7), [17])

    def test_all_clockwise_rotations_map_masks_back_to_original_sensor_grid(self):
        sensor = [[0 for _ in range(10)] for _ in range(14)]
        for y in [5, 7, 9]:
            for x in [3, 5, 7]:
                sensor[y][x] = 1
        rotated = sensor
        for rotation in (0, 90, 180, 270):
            self.assertEqual(core.sample_depth_indices(rotated, 5, 7,
                             image_rotation_degrees=rotation), [17])
            rotated = [list(row) for row in zip(*rotated[::-1])]

    def test_one_depth_pixel_erosion_removes_background_and_hole_neighbors(self):
        mask = [[1] * 7 for _ in range(7)]
        mask[3][3] = 0
        indices = core.sample_depth_indices(mask, 7, 7)
        self.assertEqual(len(indices), 16)
        self.assertTrue(all(0 < i % 7 < 6 and 0 < i // 7 < 6 for i in indices))
        self.assertTrue(all(abs(i % 7 - 3) > 1 or abs(i // 7 - 3) > 1 for i in indices))

    def test_even_sampling_keeps_full_extent_is_deterministic_and_unique(self):
        mask = [[1] * 100 for _ in range(100)]
        samples = core.sample_depth_indices(mask, 100, 100)
        self.assertEqual(len(samples), 2048)
        self.assertEqual(samples[0], 101)
        self.assertEqual(samples[-1], 9898)
        self.assertEqual(samples, sorted(set(samples)))
        self.assertEqual(samples, core.sample_depth_indices(mask, 100, 100))
        self.assertLessEqual(max(b - a for a, b in zip(samples, samples[1:])), 8)

    def test_tiny_or_empty_masks_do_not_generate_background_points(self):
        self.assertEqual(core.sample_depth_indices([[1] * 3] * 3, 2, 2), [])
        self.assertEqual(core.sample_depth_indices([[0] * 5] * 5, 5, 5), [])
        with self.assertRaises(ValueError):
            core.sample_depth_indices([[1], [1, 0]], 5, 5)

    def test_catalog_mapping_score_filter_and_detection_limit(self):
        prompts = {name: i for i, (name, _) in enumerate(core.PROMPTS)}
        self.assertEqual(core.canonical_category(prompts["armchair"]), "chair")
        self.assertEqual(core.canonical_category(prompts["trash bin"]), "waste_bin")
        self.assertEqual(core.canonical_category(prompts["podium"]), "lectern")
        self.assertIsNone(core.canonical_category(999))
        mask = [[1] * 7] * 7
        observations = [(0, 0.44, mask), (0, float("nan"), mask),
                        (999, 0.99, mask), (0, 1.1, mask)]
        observations += [(prompts["armchair"], 0.45 + i / 100, mask) for i in range(20)]
        detections = core.detections_from_masks(observations, 7, 7)
        self.assertEqual(len(detections), 16)
        self.assertTrue(all(d["category"] == "chair" for d in detections))
        self.assertEqual([d["score"] for d in detections],
                         sorted([0.45 + i / 100 for i in range(20)], reverse=True)[:16])


class ProtocolTests(unittest.TestCase):
    def test_invalid_requests_rejected_before_inference(self):
        for value in [request(depth_width=True), request(depth_height=0),
                      request(depth_width=513, depth_height=512),
                      request(color_jpeg="https://private.example/image.jpg"),
                      request(request_id=""), request(extra="field"),
                      request(image_rotation_degrees=45), request(image_rotation_degrees=True)]:
            with self.assertRaises(ValueError):
                core.decode_request(value)

    def test_persistent_worker_recovers_and_emits_one_flushed_json_line_per_frame(self):
        class Recognizer:
            calls = 0

            def predict(self, jpeg, width, height, rotation):
                self.calls += 1
                if self.calls == 1:
                    raise ValueError("private image bytes or path must never escape")
                return [{"category": "chair", "score": 0.9, "depth_indices": [8]}]

        recognizer = Recognizer()
        source = io.StringIO("bad JSON\n" + json.dumps(request("bad-inference")) + "\n"
                             + json.dumps(request("valid-frame")) + "\n")
        output = io.StringIO()
        diagnostics = io.StringIO()
        with contextlib.redirect_stderr(diagnostics):
            worker.serve(recognizer, source, output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(responses), 3)
        self.assertEqual(recognizer.calls, 2)
        self.assertEqual(responses[1], {"request_id": "bad-inference",
                                       "error": "Local recognition inference failed."})
        self.assertEqual(responses[2]["request_id"], "valid-frame")
        self.assertEqual(responses[2]["detections"][0]["category"], "chair")
        self.assertNotIn("private", output.getvalue() + diagnostics.getvalue())

    def test_oversized_line_is_drained_before_next_frame(self):
        class Recognizer:
            def predict(self, *_):
                return []

        source = io.StringIO("x" * 500 + "\n" + json.dumps(request()) + "\n")
        output = io.StringIO()
        with patch.object(worker, "MAX_REQUEST_BYTES", 256):
            worker.serve(Recognizer(), source, output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(responses), 2)
        self.assertIn("error", responses[0])
        self.assertEqual(responses[1], {"request_id": "frame-1", "detections": []})

    def test_runtime_network_guard_rejects_connection_and_resolution(self):
        for event in ("socket.connect", "socket.getaddrinfo", "socket.gethostbyname"):
            with self.assertRaises(OSError):
                worker.deny_runtime_network(event, ())
        worker.deny_runtime_network("open", ())

    def test_startup_failure_is_fatal_and_keeps_request_identity(self):
        source = io.StringIO(json.dumps(request("startup-failure")) + "\n")
        output = io.StringIO()
        worker.serve(None, source, output, startup_error="Local recognition is unavailable.")
        self.assertEqual(json.loads(output.getvalue()), {
            "request_id": "startup-failure", "error": "Local recognition is unavailable.",
            "fatal": True,
        })


@unittest.skipUnless(importlib.util.find_spec("PIL") and importlib.util.find_spec("numpy"),
                     "JPEG orientation test needs the isolated Pillow/NumPy environment")
class JpegTests(unittest.TestCase):
    def test_numpy_masks_match_dependency_free_sampling_in_every_rotation(self):
        import numpy as np
        mask = [[int((x // 4 + y // 4) % 3 != 0) for x in range(50)] for y in range(70)]
        rotated = mask
        for rotation in (0, 90, 180, 270):
            expected = core.sample_depth_indices(rotated, 25, 35, max_samples=20,
                                                 image_rotation_degrees=rotation)
            actual = core.sample_depth_indices(np.asarray(rotated), 25, 35, max_samples=20,
                                               image_rotation_degrees=rotation)
            self.assertEqual(actual, expected)
            rotated = [list(row) for row in zip(*rotated[::-1])]

    def test_exif_orientation_is_ignored_and_numpy_uses_sensor_native_bgr(self):
        from PIL import Image
        image = Image.new("RGB", (9, 5), color=(255, 0, 0))
        exif = Image.Exif()
        exif[274] = 6  # A portrait display transform must never change depth alignment.
        output = io.BytesIO()
        image.save(output, format="JPEG", exif=exif)
        pixels = worker.load_sensor_jpeg(output.getvalue())
        self.assertEqual(pixels.shape, (5, 9, 3))
        self.assertGreater(int(pixels[2, 4, 2]), 240)
        self.assertLess(int(pixels[2, 4, 0]), 10)


if __name__ == "__main__":
    unittest.main()
