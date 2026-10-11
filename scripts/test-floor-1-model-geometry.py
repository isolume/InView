#!/usr/bin/env python3
"""Focused mesh regressions; run with the reconstruction NumPy/Shapely environment."""
import importlib.util
from pathlib import Path
import unittest

import numpy as np
from shapely.geometry import Polygon
from shapely.ops import unary_union

spec = importlib.util.spec_from_file_location("prepare_floor_1", Path(__file__).with_name("prepare-floor-1-model.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class FloorTriangulationTests(unittest.TestCase):
    def assert_matches(self, polygon, height):
        record = prepare.floor_record("test", polygon, height)
        vertices = np.asarray(record["vertices"])
        faces = vertices[np.asarray(record["triangles"])]
        triangles = [Polygon(face[:, [0, 2]]) for face in faces]
        self.assertTrue(all(polygon.covers(triangle) for triangle in triangles))
        self.assertLess(unary_union(triangles).symmetric_difference(polygon).area, 1e-8)
        self.assertAlmostEqual(sum(triangle.area for triangle in triangles), polygon.area, places=8)
        self.assertTrue(np.all(np.cross(faces[:, 1]-faces[:, 0], faces[:, 2]-faces[:, 0])[:, 1] > 0))
        self.assertTrue(np.isfinite(vertices).all())
        return record

    def test_concave_cut_remains_open(self):
        polygon = Polygon([(0, 0), (8, 0), (8, 8), (5, 8), (5, 1), (3, 1), (3, 8), (0, 8)])
        self.assert_matches(polygon, 1.58)

    def test_atrium_hole_remains_open_on_sloped_surface(self):
        polygon = Polygon([(0, 0), (8, 0), (8, 8), (0, 8)], [[(2, 2), (6, 2), (6, 6), (2, 6)]])
        record = self.assert_matches(polygon, lambda x, z: 0.05*x + 0.03*z)
        self.assertEqual(len(record["holes_xz"]), 1)

    def test_ring_direction_does_not_change_mesh(self):
        polygon = Polygon([(0, 0), (8, 0), (8, 8), (0, 8)], [[(2, 2), (6, 2), (6, 6), (2, 6)]])
        self.assertEqual(self.assert_matches(polygon, 0), self.assert_matches(polygon.reverse(), 0))

    def test_nonfinite_height_and_invalid_polygon_fail(self):
        polygon = Polygon([(0, 0), (1, 0), (1, 1), (0, 1)])
        with self.assertRaises(ValueError):
            prepare.floor_record("nan", polygon, float("nan"))
        with self.assertRaises(ValueError):
            prepare.floor_record("self-crossing", Polygon([(0, 0), (1, 1), (1, 0), (0, 1)]), 0)


if __name__ == "__main__":
    unittest.main()
