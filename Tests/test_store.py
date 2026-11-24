import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_store', ROOT / 'scripts/check-store.py')
check_store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_store)


class StoreGuardTests(unittest.TestCase):
    def test_no_guard_violations(self):
        self.assertEqual(check_store.problems(), [])

    def test_purchase_word_detector(self):
        self.assertTrue(check_store.PURCHASE_WORDS.search('model.proStatus == .unlocked'))
        self.assertTrue(check_store.PURCHASE_WORDS.search('import StoreKit'))
        self.assertFalse(check_store.PURCHASE_WORDS.search('Photos saved; use the zoom slider'))

    def test_function_body_extracts_balanced_braces(self):
        text = 'func a() { if x { y() } }\nfunc b() { z() }'
        self.assertEqual(check_store.function_body(text, 'func a()'), '{ if x { y() } }')
        self.assertIsNone(check_store.function_body(text, 'func c()'))


if __name__ == '__main__':
    unittest.main()
