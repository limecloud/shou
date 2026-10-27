#!/usr/bin/env python3
"""Verify shared native design encoding and reject malformed nonuniform insets."""
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import design_tokens


class DesignTokenTests(unittest.TestCase):
    def setUp(self):
        self.tokens = {'schema_version': 1, 'colors': {}, 'numbers': {}, 'radii': {},
                       'thicknesses': {'ShouUniform': 16, 'ShouRow': [18, 17, 18, 17]}}

    def test_xaml_preserves_left_top_right_bottom_order_and_uniform_values(self):
        root = ET.fromstring(design_tokens.xaml(self.tokens))
        values = {item.attrib['{http://schemas.microsoft.com/winfx/2006/xaml}Key']: item.text for item in root}
        self.assertEqual(values, {'ShouRow': '18,17,18,17', 'ShouUniform': '16'})

    def test_swift_maps_asymmetric_edges_to_named_insets(self):
        self.tokens['thicknesses']['ShouRow'] = [1, 2, 3, 4]
        source = design_tokens.swift(self.tokens).decode()
        self.assertIn('static let `row` = EdgeInsets(top: 2, leading: 1, bottom: 4, trailing: 3)', source)
        self.assertIn('static let `uniform`: CGFloat = 16', source)

    def test_invalid_insets_are_rejected_before_generating_either_platform(self):
        for value in [[], [1], [1, 2], [1, 2, 3], [1, 2, 3, 4, 5], [1, -1, 3, 4],
                      [1, 4097, 3, 4], [1, float('inf'), 3, 4], [1, float('nan'), 3, 4],
                      [1, True, 3, 4], [1, '2', 3, 4], [1, None, 3, 4]]:
            with self.subTest(value=value):
                tokens = copy.deepcopy(self.tokens)
                tokens['thicknesses']['ShouRow'] = value
                for generate in [design_tokens.xaml, design_tokens.swift]:
                    with self.assertRaises(ValueError):
                        generate(tokens)

    def test_edge_arrays_are_not_accepted_for_numeric_or_radius_tokens(self):
        for group in ['numbers', 'radii']:
            with self.subTest(group=group):
                tokens = copy.deepcopy(self.tokens)
                tokens[group]['ShouWrongType'] = [1, 2, 3, 4]
                with self.assertRaises(ValueError):
                    design_tokens.validate(tokens)

    def test_repository_palette_has_provenance_for_every_color(self):
        tokens = design_tokens.load()
        self.assertGreater(len(tokens['colors']), 0)

    def test_resource_loading_rejects_a_color_outside_its_declared_scale(self):
        tokens = design_tokens.load()
        tokens['colors']['ShouAccent'] = '#FF010203'
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'tokens.json'
            source.write_text(json.dumps(tokens))
            with patch.object(design_tokens, 'SOURCE', source):
                with self.assertRaisesRegex(ValueError, 'ShouAccent.*Radix'):
                    design_tokens.load()


if __name__ == '__main__':
    unittest.main()
