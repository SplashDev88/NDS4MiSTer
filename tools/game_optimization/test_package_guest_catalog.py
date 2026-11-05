import json
from pathlib import Path
import tempfile
import unittest

from package_private_beta import extend_guest_catalog


class RegionalCatalogTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.catalog = {'catalog_version': 1, 'entries': []}

    def entry(self, code):
        name = code + '.json'
        (self.root / name).write_text(json.dumps({
            'game_code': code, 'revision': 0, 'header_sha1': 'a' * 40,
            'delivery': 'append-decoded-arm9-gx-spans-v1',
            'patches': [{'id': 'helper'}, {'id': 'call'}],
        }))
        return {'manifest': name, 'patch_ids': ['helper', 'call']}

    def test_multiple_regions_preserve_existing_entries(self):
        old = self.entry('OLD1')
        self.catalog = extend_guest_catalog(self.catalog, {'guest_entry': old}, self.root)
        entries = [self.entry(code) for code in ('AAA1', 'AAA2', 'AAA3', 'AAA4')]
        result = extend_guest_catalog(self.catalog, {'guest_entries': entries}, self.root)
        self.assertEqual(len(result['entries']), 5)
        self.assertEqual(result['entries'][0], self.catalog['entries'][0])
        self.assertEqual(len(self.catalog['entries']), 1)

    def test_duplicate_identity_rejected_without_partial_mutation(self):
        entry = self.entry('AAA1')
        with self.assertRaises(AssertionError):
            extend_guest_catalog(self.catalog, {'guest_entries': [entry, entry]}, self.root)
        self.assertEqual(self.catalog['entries'], [])

    def test_complete_atomic_patch_selection_required(self):
        for ids in (['helper'], ['helper', 'other'], ['helper', 'call', 'call']):
            with self.subTest(ids=ids), self.assertRaises(AssertionError):
                entry = dict(self.entry('AAA1'), patch_ids=ids)
                extend_guest_catalog(self.catalog, {'guest_entries': [entry]}, self.root)

    def test_catalog_limit(self):
        entries = [self.entry('X%03d' % n) for n in range(33)]
        with self.assertRaises(AssertionError):
            extend_guest_catalog(self.catalog, {'guest_entries': entries}, self.root)

    def test_ambiguous_or_missing_definition(self):
        for definition in ({}, {'guest_entries': []},
                           {'guest_entry': self.entry('AAA1'), 'guest_entries': []}):
            with self.subTest(definition=definition), self.assertRaises(AssertionError):
                extend_guest_catalog(self.catalog, definition, self.root)

    def test_manifest_must_stay_inside_source_tree(self):
        for path in ('../elsewhere.json', '/tmp/elsewhere.json'):
            entry = {'manifest': path, 'patch_ids': ['helper', 'call']}
            with self.subTest(path=path), self.assertRaises(AssertionError):
                extend_guest_catalog(self.catalog, {'guest_entry': entry}, self.root)


if __name__ == '__main__':
    unittest.main()
