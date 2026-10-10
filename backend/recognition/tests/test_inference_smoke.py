"""Opt in after setup: INVIEW_RECOGNITION_SMOKE=1 python -m unittest discover ..."""
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


@unittest.skipUnless(os.environ.get("INVIEW_RECOGNITION_SMOKE") == "1",
                     "real local model smoke is opt-in after setup")
class LocalInferenceSmoke(unittest.TestCase):
    def test_real_model_persists_recovers_and_emits_only_protocol(self):
        from PIL import Image
        data = io.BytesIO()
        Image.new("RGB", (96, 64), color=(180, 180, 180)).save(data, format="JPEG")
        encoded = base64.b64encode(data.getvalue()).decode()
        requests = [
            {"request_id": "synthetic-0", "color_jpeg": encoded,
             "depth_width": 48, "depth_height": 32},
            {"request_id": "invalid", "color_jpeg": "invalid JPEG",
             "depth_width": 48, "depth_height": 32},
            {"request_id": "synthetic-90", "color_jpeg": encoded,
             "depth_width": 48, "depth_height": 32, "image_rotation_degrees": 90},
        ]
        path = Path(__file__).resolve().parents[1] / "worker.py"
        result = subprocess.run([sys.executable, "-u", str(path)],
                                input="".join(json.dumps(r) + "\n" for r in requests),
                                text=True, capture_output=True, timeout=60, check=True)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["request_id"], "synthetic-0")
        self.assertIn("detections", responses[0], responses[0].get("error"))
        self.assertIn("error", responses[1])
        self.assertEqual(responses[2]["request_id"], "synthetic-90")
        self.assertIn("detections", responses[2], responses[2].get("error"))
        self.assertNotIn(encoded, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
