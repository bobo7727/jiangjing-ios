import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ROOT / '.build' / 'validation-tests'


class BuildValidationTests(unittest.TestCase):
    def setUp(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=str(SCRATCH))
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.app = self.directory / 'JiangJing.app'
        self.app.mkdir()
        self.info = {
            'CFBundleIdentifier': 'com.jiangjing.magnifier',
            'MinimumOSVersion': '16.0',
            'ITSAppUsesNonExemptEncryption': False,
            'NSCameraUsageDescription': 'Camera',
            'NSMicrophoneUsageDescription': 'Microphone',
            'NSPhotoLibraryAddUsageDescription': 'Add to Photos',
            'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}},
        }
        self.write_info()
        (self.app / 'Assets.car').write_bytes(b'test fixture')
        (self.app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False}))
        for language in ('en', 'zh-Hans'):
            folder = self.app / (language + '.lproj')
            folder.mkdir()
            for name in ('Localizable.strings', 'InfoPlist.strings'):
                (folder / name).write_text('"fixture" = "fixture";')

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def verify(self):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/verify-app.py'), str(self.app)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_complete_artifact_fixture_passes(self):
        self.assertEqual(self.verify().returncode, 0)

    def test_missing_privacy_manifest_fails(self):
        (self.app / 'PrivacyInfo.xcprivacy').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_raised_deployment_target_fails(self):
        self.info['MinimumOSVersion'] = '17.0'
        self.write_info()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_missing_localization_fails(self):
        (self.app / 'en.lproj/InfoPlist.strings').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_unconfigured_release_policy_fails_before_modifying_plist(self):
        environment = dict(os.environ)
        environment.pop('PRIVACY_POLICY_URL_EN', None)
        environment.pop('PRIVACY_POLICY_URL_ZH', None)
        folder = self.directory / 'JiangJing'
        folder.mkdir()
        target = folder / 'Info.plist'
        original = plistlib.dumps(self.info)
        target.write_bytes(original)
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/check-release-policy.py')],
                                cwd=str(self.directory), env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PRIVACY_POLICY_URL_EN', result.stderr)
        self.assertEqual(target.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
