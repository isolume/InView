import base64
import json

import cv2
import numpy as np

from inview_worker.synthetic import package, stream


def test_package_replays_as_sensor_native_chunks_with_context():
    manifest, chunks, attachments = stream.chunks_from_package(package.build())
    assert len(manifest["id"]) == 36 and manifest["floor_id"] == "ground"
    assert len(chunks) == 1 and attachments == {}
    chunk = chunks[0]
    frame = chunk["frame"]
    image = cv2.imdecode(np.frombuffer(base64.b64decode(chunk["color_jpeg"]), np.uint8), cv2.IMREAD_COLOR)
    # Sensor-native landscape at the streamed resolution, matching the scaled calibration.
    assert image.shape[:2] == (frame["camera"]["image_height"], frame["camera"]["image_width"]) == (480, 640)
    assert frame["camera"]["image_width"] / frame["camera"]["image_height"] == frame["depth"]["width"] / frame["depth"]["height"]
    assert frame["pixel_orientation"] == "sensor_native"
    assert chunk["environment"]["latitude"] == 33.7756
    assert len(chunk["surfaces"]) == 6 and chunk["poses"] == []
    json.dumps(chunk)  # Wire-serialisable.


def test_movement_interpolates_between_keyframes():
    a, b = np.eye(4), np.eye(4)
    b[:3, 3] = [4.0, 0.0, 0.0]
    poses = stream._movement(a, b, 1.0, 2.0, steps=3)
    assert [p["t"] for p in poses] == [1.25, 1.5, 1.75]
    assert [p["m"][12] for p in poses] == [1.0, 2.0, 3.0]
