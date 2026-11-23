import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_i18n', ROOT / 'scripts/check-i18n.py')
check_i18n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_i18n)


class LocalizationTests(unittest.TestCase):
    def test_no_missing_or_untranslated_text(self):
        self.assertEqual(check_i18n.problems(), [])

    def test_cjk_detector_catches_chinese_and_ignores_english(self):
        self.assertTrue(check_i18n.CJK.search('Retry 重试'))
        self.assertFalse(check_i18n.CJK.search('Retry — pinch to zoom · 1×'))

    def test_swift_comment_stripper_allows_chinese_comments_only(self):
        self.assertFalse(check_i18n.CJK.search(check_i18n.strip_swift_comments('// 中文\nlet a = 1 /* 注释 */')))
        self.assertTrue(check_i18n.CJK.search(check_i18n.strip_swift_comments('let a = "中文"')))


if __name__ == '__main__':
    unittest.main()
