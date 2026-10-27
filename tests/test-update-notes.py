#!/usr/bin/env python3
"""Exercise safe HTML rendering before release notes enter a signed feed."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('notes', Path(__file__).resolve().parents[1] / 'scripts/render-update-notes.py')
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class UpdateNotesTests(unittest.TestCase):
    def test_preserves_bilingual_paragraphs_and_lists(self):
        value = notes.render('# Shou 1.2.3\n\nRelease notes\ncontinued.\n\n- One\n- 中文更新\n')
        self.assertIn('<h3>Shou 1.2.3</h3>', value)
        self.assertIn('<p>Release notes continued.</p>', value)
        self.assertIn('<ul><li>One</li><li>中文更新</li></ul>', value)

    def test_treats_markup_and_remote_images_as_plain_text(self):
        value = notes.render('<script>alert(1)</script>\n\n- <img src="https://example.com/private"> & data')
        self.assertNotIn('<script>', value)
        self.assertNotIn('<img', value)
        self.assertIn('&lt;script&gt;', value)
        self.assertIn('&amp; data', value)

    def test_rejects_empty_and_oversize_input(self):
        for value in (' ', '中' * 50_000):
            with self.assertRaises(ValueError): notes.render(value)


if __name__ == '__main__':
    unittest.main()
