"""In-memory checks for repository configuration and the Swift identifier guard."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('repository_check', ROOT / 'scripts/check-repository.py')
CHECKER = importlib.util.module_from_spec(SPEC)
with contextlib.redirect_stdout(io.StringIO()) as IMPORT_OUTPUT:
    SPEC.loader.exec_module(CHECKER)

# Reviewed script bodies from 38086ca, including multiline Python and shell
# continuations. These expectations are independent of the layout checker.
EXPECTED_SCRIPTS = (
    r"""#!/usr/bin/env bash
set -euo pipefail
mkdir -p build
git log -1 --format="Build commit: %H %s" | tee build/commit.txt
xcodebuild -version | tee build/xcode-version.txt
swift --version | tee build/swift-version.txt
source scripts/install-xcodegen.sh
"$XCODEGEN_BIN" generate
test -f JiangJing.xcodeproj/xcshareddata/xcschemes/JiangJing.xcscheme
""",
    r"""#!/usr/bin/env bash
set -euo pipefail
python3 scripts/check-repository.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
swift test -Xswiftc -strict-concurrency=complete 2>&1 | tee build/core-tests.log
SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
choices = [d["udid"] for runtime, entries in devices.items() if "iOS" in runtime
           for d in entries if d.get("isAvailable") and "iPhone" in d["name"]]
assert choices, "No available iPhone Simulator runtime"
print(choices[0])')
xcodebuild test -project JiangJing.xcodeproj -scheme JiangJing \
  -destination "id=$SIMULATOR_ID" -resultBundlePath build/Regression.xcresult \
  -derivedDataPath build/TestDerivedData CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete 2>&1 | tee build/ios-tests.log
""",
    r"""#!/usr/bin/env bash
set -euo pipefail
xcodebuild -project JiangJing.xcodeproj -scheme JiangJing \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_STRICT_CONCURRENCY=complete build 2>&1 | tee build/simulator-build.log
APP_PATH="$CM_BUILD_DIR/build/DerivedData/Build/Products/Debug-iphonesimulator/JiangJing.app"
python3 scripts/verify-app.py "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" build/JiangJing-ios-simulator.zip
""",
    r"""#!/usr/bin/env bash
set -euo pipefail
xcodebuild -project JiangJing.xcodeproj -scheme JiangJing \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ReleaseDerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_STRICT_CONCURRENCY=complete build 2>&1 | tee build/release-build.log
python3 scripts/verify-app.py build/ReleaseDerivedData/Build/Products/Release-iphoneos/JiangJing.app
""",
    r"""#!/usr/bin/env bash
set -euo pipefail
: "${APP_STORE_APPLE_ID:?Set the numeric Apple ID in jiangjing_release}"
[[ "$APP_STORE_APPLE_ID" =~ ^[0-9]+$ ]] || { echo 'APP_STORE_APPLE_ID must be numeric' >&2; exit 1; }
: "${PROJECT_BUILD_NUMBER:?Codemagic must provide PROJECT_BUILD_NUMBER}"
[[ "$PROJECT_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'PROJECT_BUILD_NUMBER must be positive' >&2; exit 1; }
python3 scripts/check-release-policy.py
mkdir -p build
git log -1 --format="Build commit: %H %s" | tee build/commit.txt
xcodebuild -version | tee build/xcode-version.txt
swift --version | tee build/swift-version.txt
source scripts/install-xcodegen.sh
"$XCODEGEN_BIN" generate
test -f JiangJing.xcodeproj/xcshareddata/xcschemes/JiangJing.xcscheme
""",
    r"""#!/usr/bin/env bash
set -euo pipefail
xcode-project use-profiles
xcrun agvtool new-version -all "$PROJECT_BUILD_NUMBER"
""",
    r"""#!/usr/bin/env bash
set -euo pipefail
xcode-project build-ipa --project JiangJing.xcodeproj --scheme JiangJing \
  --archive-directory build/ios/archive \
  --export-options-plist=/Users/builder/export_options.plist 2>&1 | tee build/archive.log
""",
)


class SwiftPixelFormatKeyTests(unittest.TestCase):
    def test_invalid_key_reports_one_based_line_number(self):
        text = '\nlet settings = [\n    kCVPixelFormatTypeKey as String: 0\n]\n'
        with self.assertRaises(CHECKER.ConfigurationError) as failure:
            CHECKER.check_swift_pixel_format_key(text, 'JiangJing/Camera/CameraController.swift')
        self.assertEqual(str(failure.exception),
                         'JiangJing/Camera/CameraController.swift:3: '
                         'use kCVPixelBufferPixelFormatTypeKey')

    def test_first_line_is_one(self):
        with self.assertRaisesRegex(CHECKER.ConfigurationError, r'^Example.swift:1: use '):
            CHECKER.check_swift_pixel_format_key('kCVPixelFormatTypeKey', 'Example.swift')

    def test_correct_key_bgra_and_longer_identifiers_are_allowed(self):
        for identifier in ('kCVPixelBufferPixelFormatTypeKey', 'kCVPixelFormatType_32BGRA',
                           'kCVPixelFormatTypeKeySuffix', 'prefixkCVPixelFormatTypeKey',
                           '_kCVPixelFormatTypeKey', 'kCVPixelFormatTypeKey_'):
            with self.subTest(identifier=identifier):
                CHECKER.check_swift_pixel_format_key(identifier, 'Example.swift')

    def test_comments_and_strings_are_also_rejected(self):
        for line in ('// kCVPixelFormatTypeKey', '/* kCVPixelFormatTypeKey */',
                     'let name = "kCVPixelFormatTypeKey"'):
            with self.subTest(line=line), self.assertRaisesRegex(
                    CHECKER.ConfigurationError, r'^Example.swift:2: use '):
                CHECKER.check_swift_pixel_format_key('\n' + line, 'Example.swift')

    def test_scan_discovers_and_reads_both_source_directories(self):
        sources = [ROOT / 'JiangJing/Camera/CameraController.swift',
                   ROOT / 'JiangJingTests/ExampleTests.swift']

        def discover(directory, pattern):
            self.assertEqual(pattern, '*.swift')
            return iter(source for source in sources if directory in source.parents)

        with mock.patch.object(Path, 'rglob', autospec=True, side_effect=discover) as rglob, \
                mock.patch.object(Path, 'read_text', autospec=True,
                                  return_value='kCVPixelBufferPixelFormatTypeKey') as read:
            CHECKER.check_swift_pixel_format_keys()
        self.assertEqual(rglob.call_args_list, [
            mock.call(ROOT / 'JiangJing', '*.swift'),
            mock.call(ROOT / 'JiangJingTests', '*.swift')])
        self.assertEqual(read.call_args_list, [
            mock.call(source, encoding='utf-8') for source in sources])

    def test_scan_rejects_invalid_key_in_either_directory(self):
        for directory in ('JiangJing', 'JiangJingTests'):
            with self.subTest(directory=directory):
                source = ROOT / directory / 'Example.swift'

                def discover(path, pattern):
                    return iter([source] if path == source.parent else [])

                with mock.patch.object(Path, 'rglob', autospec=True, side_effect=discover), \
                        mock.patch.object(Path, 'read_text', autospec=True,
                                          return_value='\nkCVPixelFormatTypeKey'), \
                        self.assertRaises(CHECKER.ConfigurationError) as failure:
                    CHECKER.check_swift_pixel_format_keys()
                self.assertEqual(str(failure.exception),
                                 directory + '/Example.swift:2: '
                                 'use kCVPixelBufferPixelFormatTypeKey')

    def test_entry_point_runs_swift_guard(self):
        with mock.patch.object(CHECKER, 'check_swift_pixel_format_keys',
                               side_effect=CHECKER.ConfigurationError('guard failed')) as scan, \
                self.assertRaisesRegex(CHECKER.ConfigurationError, '^guard failed$'):
            CHECKER.main()
        scan.assert_called_once_with()


class RepositoryConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with (ROOT / 'codemagic.yaml').open(encoding='utf-8', newline='') as source:
            cls.codemagic = source.read()
        with (ROOT / 'project.yml').open(encoding='utf-8', newline='') as source:
            cls.project = source.read()

    def check(self, codemagic=None, project=None):
        return CHECKER.check_configuration(
            self.codemagic if codemagic is None else codemagic,
            self.project if project is None else project)

    def test_import_does_not_run_repository_checks(self):
        self.assertEqual(IMPORT_OUTPUT.getvalue(), '')

    def test_restored_configuration_and_all_seven_scripts(self):
        self.assertEqual(len(EXPECTED_SCRIPTS), 7)
        self.assertEqual(self.check(), list(EXPECTED_SCRIPTS))

    def test_shell_checks_use_stdin_without_evaluation(self):
        with mock.patch.object(CHECKER.subprocess, 'run') as run:
            self.check()
        self.assertEqual(run.call_args_list, [
            mock.call(['bash', '-n'], input=body, text=True, check=True)
            for body in EXPECTED_SCRIPTS])

    def test_additional_valid_script_is_allowed(self):
        changed = self.codemagic.replace(
            '    artifacts:',
            '      - name: Additional check\n        script: |\n          true\n    artifacts:', 1)
        self.assertEqual(self.check(changed),
                         list(EXPECTED_SCRIPTS[:4]) + ['true\n'] + list(EXPECTED_SCRIPTS[4:]))

    def test_wrong_or_unquoted_app_deployment_fails_with_other_versions_present(self):
        for value in ('"17.0"', '16.0'):
            with self.subTest(value=value):
                changed = self.project.replace('    deploymentTarget: "16.0"',
                                               '    deploymentTarget: ' + value, 1)
                self.assertIn('iOS: "16.0"', changed)
                self.assertIn('IPHONEOS_DEPLOYMENT_TARGET: "16.0"', changed)
                with self.assertRaisesRegex(CHECKER.ConfigurationError, 'deploymentTarget'):
                    self.check(project=changed)

    def test_missing_test_target_fails_despite_scheme_references(self):
        start = self.project.index('  JiangJingTests:\n')
        end = self.project.index('schemes:\n', start)
        changed = self.project[:start] + self.project[end:]
        self.assertIn('JiangJingTests: [test]', changed)
        self.assertIn('targets: [JiangJingTests]', changed)
        with self.assertRaisesRegex(CHECKER.ConfigurationError, 'JiangJingTests'):
            self.check(project=changed)

    def test_app_and_deployment_must_be_in_immediate_target_mapping(self):
        variants = (
            self.project.replace('\ntargets:\n', '\nother_targets:\n', 1),
            self.project.replace('  JiangJing:\n', '  OtherApp:\n', 1),
            self.project.replace('    deploymentTarget: "16.0"\n', '', 1),
        )
        for changed in variants:
            with self.subTest(project=changed), self.assertRaises(CHECKER.ConfigurationError):
                self.check(project=changed)

    def test_simulator_publishing_and_integrations_are_rejected(self):
        for key in ('publishing', 'integrations'):
            with self.subTest(key=key), self.assertRaisesRegex(
                    CHECKER.ConfigurationError, 'ios-simulator'):
                self.check(self.codemagic.replace(
                    '  ios-simulator:\n', '  ios-simulator:\n    ' + key + ':\n      example: true\n'))

    def test_triggering_is_rejected_on_every_workflow(self):
        for name in ('ios-simulator', 'ios-testflight'):
            with self.subTest(name=name), self.assertRaisesRegex(
                    CHECKER.ConfigurationError, name + ' must not have triggering'):
                self.check(self.codemagic.replace(
                    '  ' + name + ':\n',
                    '  ' + name + ':\n    triggering:\n      events:\n        - push\n'))

    def test_release_settings_and_display_name_remain_allowed(self):
        self.assertIn('no publishing', self.codemagic)
        self.assertIn('    integrations:\n', self.codemagic)
        self.assertIn('    publishing:\n', self.codemagic)
        changed = self.codemagic.replace('      xcode: "26.6"',
            '      xcode: "26.6"\n      publishing: false\n      integrations: false\n'
            '      triggering: false', 1)
        self.check(changed)

    def test_literal_script_punctuation_is_not_structural_yaml(self):
        changed = self.codemagic.replace('          set -euo pipefail',
            '          # &anchor *alias !tag {mapping} publishing: triggering:\n'
            '          printf "%s\\n" "[literal] # data"\n          set -euo pipefail', 1)
        self.check(changed)

    def test_quoted_punctuation_comments_flow_lists_and_globs_are_supported(self):
        for display in ('"no publishing &anchor *alias !tag # literal"',
                        "'no publishing &anchor *alias !tag # literal'",
                        "'owner''s no publishing'"):
            with self.subTest(display=display):
                changed = self.codemagic.replace(
                    'name: iOS compile and regression checks - no publishing',
                    'name: ' + display + ' # comment: &ignored')
                self.check(changed)
        self.assertIn('JiangJingTests: [test]', self.project)
        self.assertIn('build/ios/**/*.dSYM', self.codemagic)

    def test_duplicate_structural_keys_are_rejected(self):
        variants = (
            ('workflows:', 'workflows:\nworkflows:'),
            ('  ios-simulator:', '  ios-simulator: old\n  ios-simulator:'),
            ('    scripts:', '    scripts: old\n    scripts:'),
            ('        script: |', '        script: old\n        script: |'),
        )
        for original, replacement in variants:
            with self.subTest(key=original), self.assertRaisesRegex(
                    CHECKER.ConfigurationError, 'duplicate key|script: \\||expected an indented'):
                self.check(self.codemagic.replace(original, replacement, 1))
        for original, replacement in (
            ('targets:', 'targets: old\ntargets:'),
            ('  JiangJing:', '  JiangJing: old\n  JiangJing:'),
            ('    deploymentTarget: "16.0"',
             '    deploymentTarget: "17.0"\n    deploymentTarget: "16.0"'),
        ):
            with self.subTest(key=original), self.assertRaises(CHECKER.ConfigurationError):
                self.check(project=self.project.replace(original, replacement, 1))

    def test_unsupported_script_forms_fail_clearly(self):
        for value in ('echo ok', '"echo ok"', "'echo ok'", '>', '|-', '|+', '|2', '&body |', '*body'):
            with self.subTest(value=value), self.assertRaisesRegex(
                    CHECKER.ConfigurationError, 'only script: \\|'):
                self.check(self.codemagic.replace('script: |', 'script: ' + value, 1))

    def test_missing_or_misplaced_scripts_are_rejected(self):
        variants = (
            self.codemagic.replace('    scripts:', '    other_steps:', 1),
            self.codemagic.replace('        script: |', '        other_body: |', 1),
            self.codemagic.replace('workflows:', 'script: |\n  true\nworkflows:', 1),
        )
        for changed in variants:
            with self.subTest(config=changed), self.assertRaises(CHECKER.ConfigurationError):
                self.check(changed)

    def test_unsupported_layouts_and_concealed_keys_are_rejected(self):
        variants = (
            self.codemagic.replace('  ios-simulator:', '   ios-simulator:', 1),
            self.codemagic.replace('    scripts:', '      scripts:', 1),
            self.codemagic.replace('    scripts:', '\tscripts:', 1),
            self.codemagic.replace('  ios-simulator:', '  "ios-simulator":', 1),
            self.codemagic.replace('  ios-simulator:', "  'ios-simulator':", 1),
            self.codemagic.replace('workflows:', 'workflows: &workflows', 1),
            self.codemagic.replace('workflows:', 'workflows: !custom', 1),
            self.codemagic.replace('    scripts:', '    <<: *defaults\n    scripts:', 1),
            self.codemagic.replace('    scripts:', '    ? triggering\n    : true\n    scripts:', 1),
            self.codemagic.replace('    scripts:', '    metadata: {triggering: true}\n    scripts:', 1),
            self.codemagic.replace('    scripts:', '    metadata: [*alias]\n    scripts:', 1),
            self.codemagic.replace('    scripts:', '    metadata: |\n      text\n    scripts:', 1),
            self.codemagic.replace('          #!/usr/bin/env bash', '           #!/usr/bin/env bash', 1),
            self.codemagic.replace('        script: |', '         script: |', 1),
            '%YAML 1.2\n' + self.codemagic,
            '---\n' + self.codemagic,
            self.codemagic + '\n---\nworkflows: {}\n',
            self.codemagic.replace('    environment:', '    environment: *defaults', 1),
        )
        for changed in variants:
            with self.subTest(config=changed), self.assertRaises(CHECKER.ConfigurationError):
                self.check(changed)
        with self.assertRaises(CHECKER.ConfigurationError):
            self.check(project=self.project.replace('targets:', 'targets: &targets', 1))

    def test_carriage_returns_are_rejected_in_either_input(self):
        for changed in (self.codemagic.replace('\n', '\r\n'),
                        self.codemagic.replace('set -euo pipefail', 'set -euo\r pipefail', 1)):
            with self.subTest(config=changed), self.assertRaisesRegex(
                    CHECKER.ConfigurationError, 'line ending'):
                self.check(changed)
        with self.assertRaisesRegex(CHECKER.ConfigurationError, 'line ending'):
            self.check(project=self.project.replace('\n', '\r\n'))

    def test_entry_point_reads_configuration_without_newline_translation(self):
        original_open = Path.open

        def open_config(path, *args, **kwargs):
            if path.name in ('codemagic.yaml', 'project.yml'):
                self.assertEqual(kwargs.get('newline'), '')
                text = self.codemagic if path.name == 'codemagic.yaml' else self.project
                return io.StringIO(text.replace('\n', '\r\n'))
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, 'open', open_config), \
                contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaisesRegex(CHECKER.ConfigurationError, 'line ending'):
            CHECKER.main()

    def test_invalid_shell_syntax_fails(self):
        run = subprocess.run
        with mock.patch.object(CHECKER.subprocess, 'run',
                               side_effect=lambda *args, **kwargs: run(
                                   *args, capture_output=True, **kwargs)), \
                self.assertRaises(subprocess.CalledProcessError) as failure:
            self.check(self.codemagic.replace('set -euo pipefail', 'if then', 1))
        self.assertIn('syntax error', failure.exception.stderr)


if __name__ == '__main__':
    unittest.main()
