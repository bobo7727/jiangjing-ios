import builtins
import contextlib
import copy
import datetime
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
NOTIFIER = ROOT / 'scripts/notify-grokbot.sh'

# A local curl substitute records only test credentials; it never uses a network.
CURL_STUB = r'''
import json, os, pathlib, re, stat, sys
from urllib.parse import urlsplit
args = sys.argv[1:]

def validate_and_simulate():
    # An explicit allowlist rejects duplicate/extra URLs, configs, protocol
    # overrides and every redirect-following option, including short forms.
    assert args[0] == '--disable'
    switches = {'--disable', '--globoff', '--silent', '--fail'}
    values = {'--proto': '=https', '--max-redirs': '0', '--output': os.devnull,
              '--connect-timeout': '3', '--max-time': '8', '--retry': '2',
              '--retry-delay': '1', '--retry-max-time': '18', '--request': 'POST',
              '--config': None, '--header': None, '--data-binary': None}
    seen = {}
    index = 0
    while index < len(args):
        flag = args[index]
        assert flag not in seen, 'duplicate option'
        if flag in switches:
            seen[flag] = True
            index += 1
        else:
            assert flag in values, 'unexpected option or URL'
            value = args[index + 1]
            assert values[flag] is None or value == values[flag], 'incorrect option value'
            seen[flag] = value
            index += 2
    assert set(seen) == switches | set(values), 'missing options'
    assert seen['--header'].startswith('@') and seen['--data-binary'].startswith('@')
    paths = [pathlib.Path(seen['--config']), pathlib.Path(seen['--header'][1:]),
             pathlib.Path(seen['--data-binary'][1:])]
    config = paths[0].read_text()
    assert re.fullmatch(r'url = "(?:[^"\\\n]|\\.)*"\n', config), 'config must contain only one URL'
    url = json.loads(config[len('url = '):])
    assert urlsplit(url).scheme == 'https' and urlsplit(url).hostname, 'HTTPS required'
    assert url not in args
    headers = paths[1].read_text()
    assert headers.splitlines()[0][len('Authorization: Bearer '):] not in args
    scenario = os.environ.get('CURL_SCENARIO', 'success')
    # These are simulations of curl's contract, not real network attempts.
    budget = 1 + int(seen['--retry']) if scenario == 'retryable' else 1
    attempts = [paths[2].read_bytes().hex() for _ in range(budget)]
    redirect = {'redirect_https': 'https://other.example.invalid/target',
                'redirect_http': 'http://other.example.invalid/target'}.get(scenario)
    return {
        'config': config, 'headers': headers,
        'payload': json.loads(paths[2].read_bytes()),
        'simulated_attempts': attempts, 'simulated_redirect': redirect,
        'simulated_requested_urls': [url] * budget,
        'modes': [stat.S_IMODE(path.stat().st_mode) for path in paths],
        'directory_mode': stat.S_IMODE(paths[0].parent.stat().st_mode),
        'paths': [str(path) for path in paths],
        'inherited_secrets': [key for key in os.environ if key.startswith('GROKBOT_WEBHOOK_')],
    }

record = {'args': args}
try:
    record.update(validate_and_simulate())
except Exception as error:
    record['contract_error'] = str(error) or type(error).__name__
# Append one record per actual process invocation, never overwrite an earlier one.
with open(os.environ['CURL_RECORD'], 'a') as stream:
    stream.write(json.dumps(record) + '\n')
if 'contract_error' in record:
    sys.exit(97)
print('simulated response body')
print('simulated secret diagnostic', file=sys.stderr)
sys.exit(22 if os.environ.get('CURL_SCENARIO') == 'retryable'
         else int(os.environ.get('CURL_EXIT', '0')))
'''


class GrokBotNotificationTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.build/notification-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.home = self.directory / 'home'
        self.home.mkdir()
        self.temp = self.directory / 'tmp'
        self.temp.mkdir()
        self.bin = self.directory / 'bin'
        self.bin.mkdir()
        (self.bin / 'python3').symlink_to(sys.executable)
        curl = self.bin / 'curl'
        curl.write_text('#!' + sys.executable + '\n' + CURL_STUB)
        curl.chmod(0o700)
        self.record = self.directory / 'record.jsonl'
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith(('GROKBOT_', 'CM_', 'CODEMAGIC_'))
                            and key not in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS')}
        self.environment.update({
            'HOME': str(self.home), 'TMPDIR': str(self.temp),
            'PATH': str(self.bin), 'CURL_RECORD': str(self.record),
            'GROKBOT_WEBHOOK_URL': 'https://notify.example.invalid/routine?secret=test',
            'GROKBOT_WEBHOOK_KEY': 'test-secret',
            'CM_BUILD_ID': 'build-current', 'CM_PROJECT_ID': 'app-id',
            'CM_BRANCH': 'feature/引号"\\\nnext', 'CM_COMMIT': 'abc"123',
        })

    def marker(self, build_id='build-current'):
        (self.home / ('codemagic-success-' + build_id)).touch()

    def run_notifier(self, workflow='ios-simulator', trace=False):
        previous = len(self.record.read_text().splitlines()) if self.record.exists() else 0
        result = subprocess.run(['/bin/bash', *(['-x'] if trace else []), str(NOTIFIER), workflow],
                                env=self.environment, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '+ set +x\n' if trace else '')
        self.assertEqual(list(self.temp.iterdir()), [], 'Temporary credentials must be cleaned up')
        records = [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []
        self.invocations = records[previous:]
        self.assertLessEqual(len(self.invocations), 1, 'Notifier must invoke curl at most once')
        for record in self.invocations:
            self.assertNotIn('contract_error', record, record)
        return self.invocations[0] if self.invocations else None

    def test_simulator_success_payload_and_private_bounded_delivery(self):
        self.marker()
        before = datetime.datetime.now(datetime.timezone.utc)
        record = self.run_notifier()
        payload = record['payload']
        timestamp = datetime.datetime.fromisoformat(payload.pop('timestamp').replace('Z', '+00:00'))
        self.assertLessEqual(before, timestamp)
        self.assertLessEqual(timestamp, datetime.datetime.now(datetime.timezone.utc))
        self.assertEqual(payload, {
            'source': 'codemagic', 'app': 'jiangjing-ios', 'workflow': 'ios-simulator',
            'build_id': 'build-current', 'app_id': 'app-id',
            'build_url': 'https://codemagic.io/app/app-id/build/build-current',
            'status': 'success', 'branch': self.environment['CM_BRANCH'],
            'commit': self.environment['CM_COMMIT'],
        })
        self.assertEqual(record['headers'], 'Authorization: Bearer test-secret\nContent-Type: application/json\n')
        self.assertEqual(record['config'], 'url = ' + json.dumps(self.environment['GROKBOT_WEBHOOK_URL']) + '\n')
        self.assertEqual(record['modes'], [0o600] * 3)
        self.assertEqual(record['directory_mode'], 0o700)
        self.assertEqual(record['inherited_secrets'], [])
        self.assertTrue(all(not Path(path).exists() for path in record['paths']))
        self.assertEqual(len(record['simulated_attempts']), 1)
        args = record['args']
        self.assertEqual(args[0], '--disable')
        for flag, value in {'--proto': '=https', '--max-redirs': '0', '--request': 'POST',
                            '--connect-timeout': '3', '--max-time': '8', '--retry': '2',
                            '--retry-delay': '1', '--retry-max-time': '18'}.items():
            self.assertEqual(args[args.index(flag) + 1], value)
        for flag in ('--silent', '--fail', '--globoff'):
            self.assertIn(flag, args)
        self.assertNotIn('--location', args)
        self.assertNotIn(self.environment['GROKBOT_WEBHOOK_URL'], args)
        self.assertNotIn(self.environment['GROKBOT_WEBHOOK_KEY'], args)

    def test_missing_or_stale_marker_means_simulator_failed(self):
        self.marker('build-old')
        self.assertEqual(self.run_notifier()['payload']['status'], 'failed')

    def test_testflight_always_finished_with_marker_hint(self):
        for marker in ('absent', 'present'):
            with self.subTest(marker=marker):
                if marker == 'present':
                    self.marker()
                payload = self.run_notifier('ios-testflight')['payload']
                self.assertEqual(payload['status'], 'finished')
                self.assertEqual(payload['build_id'], 'build-current')
                self.assertEqual(payload['script_marker'], marker)
                self.assertEqual(payload['workflow'], 'ios-testflight')
                self.assertEqual(set(payload), {'source', 'app', 'workflow', 'build_id', 'app_id',
                                               'build_url', 'status', 'branch', 'commit',
                                               'timestamp', 'script_marker'})

    def test_credentials_strip_all_cr_lf_and_inherited_tracing_is_disabled(self):
        self.environment['GROKBOT_WEBHOOK_KEY'] = '\rtest-\nsecret\r\n'
        self.environment['GROKBOT_WEBHOOK_URL'] += '\r\n'
        record = self.run_notifier(trace=True)
        self.assertIn('Authorization: Bearer test-secret\n', record['headers'])
        self.assertNotIn('\\r', record['config'])
        self.assertNotIn('\\n', record['config'])

    def test_empty_or_unset_credentials_are_silent_noop(self):
        for key in ('GROKBOT_WEBHOOK_URL', 'GROKBOT_WEBHOOK_KEY'):
            original = self.environment.pop(key)
            for value in (None, '', '\r\n'):
                with self.subTest(key=key, value=value):
                    if value is not None:
                        self.environment[key] = value
                    self.assertIsNone(self.run_notifier())
            self.environment[key] = original

    def test_invalid_url_is_silent_noop(self):
        for url in ('http://example.invalid', 'ftp://example.invalid', 'file:///tmp/target',
                    '//example.invalid', 'https://', 'https://user:pass@example.invalid',
                    'https://user@example.invalid', 'https://example.invalid:bad',
                    'https://example.invalid:99999', 'https://[bad',
                    'https://example.invalid/a b', 'https://example.invalid/#fragment',
                    'https://example.invalid/\\bad', 'https://example.invalid/\x01'):
            with self.subTest(url=url):
                self.environment['GROKBOT_WEBHOOK_URL'] = url
                self.assertIsNone(self.run_notifier())
                self.assertEqual(self.invocations, [])

    def test_retryable_failure_simulation_uses_bounded_identical_payload(self):
        self.environment['CURL_SCENARIO'] = 'retryable'
        record = self.run_notifier()
        self.assertEqual(len(self.invocations), 1)
        self.assertEqual(len(record['simulated_attempts']), 3)
        self.assertEqual(len(set(record['simulated_attempts'])), 1)
        self.assertEqual(record['simulated_requested_urls'],
                         [self.environment['GROKBOT_WEBHOOK_URL']] * 3)

    def test_redirect_simulations_never_request_redirect_target(self):
        for scenario, target in (('redirect_https', 'https://other.example.invalid/target'),
                                 ('redirect_http', 'http://other.example.invalid/target')):
            with self.subTest(scenario=scenario):
                self.environment['CURL_SCENARIO'] = scenario
                record = self.run_notifier()
                self.assertEqual(len(self.invocations), 1)
                self.assertEqual(record['simulated_redirect'], target)
                self.assertEqual(record['simulated_requested_urls'],
                                 [self.environment['GROKBOT_WEBHOOK_URL']])

    def test_delivery_failures_are_silent_and_clean_up(self):
        for exit_code in ('6', '22', '28', '60'):
            with self.subTest(exit_code=exit_code):
                self.environment['CURL_EXIT'] = exit_code
                self.assertIsNotNone(self.run_notifier())
                self.assertEqual(len(self.invocations), 1)

    def test_missing_tools_are_silent(self):
        (self.bin / 'curl').unlink()
        self.assertIsNone(self.run_notifier())
        (self.bin / 'python3').unlink()
        self.assertIsNone(self.run_notifier())

    def test_temporary_storage_failure_is_silent(self):
        # tempfile cannot use any fallback when all candidate directories fail.
        self.environment['PYTHONPATH'] = str(self.directory)
        (self.directory / 'sitecustomize.py').write_text(
            'import tempfile\n'
            'def unavailable(*args, **kwargs):\n'
            '    raise OSError("simulated unavailable temporary storage")\n'
            'tempfile.TemporaryDirectory = unavailable\n')
        self.assertIsNone(self.run_notifier())

    def test_serialization_failure_is_silent(self):
        # Unix environment bytes may decode to a surrogate, invalid in UTF-8 JSON.
        self.environment['CM_BRANCH'] = 'invalid-\udcff'
        self.assertIsNone(self.run_notifier())

    def test_unknown_workflow_is_silent_noop(self):
        self.assertIsNone(self.run_notifier('unknown'))

    def test_missing_build_id_cannot_match_marker(self):
        self.marker('')
        self.environment.pop('CM_BUILD_ID')
        self.assertEqual(self.run_notifier()['payload']['status'], 'failed')

    @unittest.skipIf(yaml is None, 'PyYAML is not installed')
    def test_yaml_marker_is_last_best_effort_and_skipped_after_script_failure(self):
        workflows = yaml.safe_load((ROOT / 'codemagic.yaml').read_text())['workflows']
        for workflow_id, workflow in workflows.items():
            marker = workflow['scripts'][-1]['script']
            result = subprocess.run(['/bin/bash', '-e', '-c', 'false\n' + marker],
                                    env=self.environment, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            payload = self.run_notifier(workflow_id)['payload']
            self.assertEqual(payload['status'], 'failed' if workflow_id == 'ios-simulator' else 'finished')
            # Restore touch for the ordinary marker step, outside the curl-only PATH.
            environment = dict(self.environment, PATH='/usr/bin:/bin')
            result = subprocess.run(['/bin/bash', '-e', '-c', marker], env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertTrue((self.home / 'codemagic-success-build-current').exists())
            (self.home / 'codemagic-success-build-current').unlink()
            environment['HOME'] = str(self.directory / 'nonexistent')
            self.assertEqual(subprocess.run(['/bin/bash', '-e', '-c', marker],
                                           env=environment, capture_output=True).returncode, 0)


class NotificationRepositoryGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with contextlib.redirect_stdout(io.StringIO()):
            cls.checker = runpy.run_path(str(ROOT / 'scripts/check-repository.py'))

    def test_trace_guard_rejects_enabling_flags(self):
        guard = self.checker['enables_shell_tracing']
        for source in ('set -x', 'set -eux', 'set -o xtrace', 'set -eo xtrace',
                       'set -o errexit -x', "set '-x'", 'true; set -x', 'set +e -x',
                       'bash -x scripts/notify-grokbot.sh', 'sh -eux script',
                       '/bin/bash -o xtrace script', '/bin/sh -ex script',
                       'bash -x -- script', 'sh -o errexit -x script',
                       '#!/bin/bash -x\ntrue', '#!/usr/bin/env bash -eux\ntrue',
                       '#!/usr/bin/env -S sh -o xtrace\ntrue',
                       'echo ok # inline comment\nset -x',
                       'echo word#literal\nbash -x script', '\\\nset -x',
                       'if true; then bash -x script; fi',
                       'FLAG=value /bin/sh -x script',
                       "cat <<'EOF'\nquoted ' data\nEOF\nset -x"):
            with self.subTest(source=source):
                self.assertTrue(guard(source))
        for source in ('set +x', 'set -euo pipefail', 'set +o xtrace', '# set -x', 'set -- -x',
                       'bash script -x', 'sh -- script -x', 'bash +x script',
                       'bash --posix script',
                       'bash -o errexit script -x', '# bash -x script',
                       'echo "set -x"', "printf '%s' 'bash -x script'",
                       "cat <<'EOF'\nset -x\nbash -x script\nunclosed '\nEOF\nset +x",
                       'cat <<-EOF\n\tsh -x script\n\tEOF\nset +o xtrace',
                       "python3 -c 'print(\"set -x\")'", 'echo "<<EOF"',
                       'cat <<<"set -x"', 'echo ok;# bash -x script\nset +x',
                       'echo ok # bash -x script\nset +x'):
            with self.subTest(source=source):
                self.assertFalse(guard(source))

    def test_trace_guard_reports_tokenization_errors(self):
        for source in ("echo 'unclosed", "cat <<'EOF'\nmissing delimiter"):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, 'shell'):
                self.checker['enables_shell_tracing'](source)

    def workflow(self, workflow_id='ios-simulator'):
        return {
            'scripts': [
                {'name': 'Build', 'script': 'true\n'},
                {'name': 'Mark ordinary scripts complete (best effort)', 'script':
                 'if [ -n "${CM_BUILD_ID:-}" ]; then\n'
                 '  touch "$HOME/codemagic-success-$CM_BUILD_ID" 2>/dev/null || true\nfi\n'}],
            'publishing': {'scripts': [{'name': 'Notify Grok Bot', 'script':
                                       f'bash scripts/notify-grokbot.sh {workflow_id} || true'}]}}

    def test_marker_guard_requires_exact_final_step(self):
        guard = self.checker['check_workflow_scripts']
        for workflow_id in ('ios-simulator', 'ios-testflight'):
            workflow = self.workflow(workflow_id)
            guard(workflow_id, workflow)
            marker = workflow['scripts'][-1]['script']
            for changed in ('# ' + marker.replace('\n', '\n# '),
                            marker + 'echo extra\n', marker.replace('$HOME/', '/tmp/'),
                            marker.replace('  touch', '# touch'),
                            marker.replace('  touch', '    touch')):
                with self.subTest(workflow=workflow_id, script=changed):
                    invalid = copy.deepcopy(workflow)
                    invalid['scripts'][-1]['script'] = changed
                    with self.assertRaisesRegex(AssertionError, 'match exactly'):
                        guard(workflow_id, invalid)
            workflow['scripts'][-1]['name'] = 'Wrong marker name'
            with self.assertRaisesRegex(AssertionError, 'Final ordinary step'):
                guard(workflow_id, workflow)

    def test_marker_guard_rejects_earlier_marker_references(self):
        for source in ('touch "$HOME/codemagic-success-$CM_BUILD_ID"',
                       '# codemagic-success- is mentioned earlier'):
            with self.subTest(source=source):
                workflow = self.workflow()
                workflow['scripts'][0]['script'] = source
                with self.assertRaisesRegex(AssertionError, 'outside final step'):
                    self.checker['check_workflow_scripts']('ios-simulator', workflow)

    def test_workflow_guard_rejects_tracing_and_preserves_exact_publisher(self):
        workflow = self.workflow()
        workflow['scripts'][0]['script'] = 'bash -x scripts/notify-grokbot.sh'
        with self.assertRaisesRegex(AssertionError, 'shell tracing'):
            self.checker['check_workflow_scripts']('ios-simulator', workflow)
        for script in (' bash scripts/notify-grokbot.sh ios-simulator || true',
                       'bash -x scripts/notify-grokbot.sh ios-simulator || true'):
            workflow = self.workflow()
            workflow['publishing']['scripts'][0]['script'] = script
            with self.assertRaises(AssertionError):
                self.checker['check_workflow_scripts']('ios-simulator', workflow)

    def test_missing_pyyaml_skips_only_yaml_checks(self):
        original_import = builtins.__import__

        def without_yaml(name, *args, **kwargs):
            if name == 'yaml':
                raise ImportError('simulated missing PyYAML')
            return original_import(name, *args, **kwargs)

        output = io.StringIO()
        with mock.patch('builtins.__import__', side_effect=without_yaml), \
                mock.patch('subprocess.run', wraps=subprocess.run) as shell_checks, \
                contextlib.redirect_stdout(output):
            runpy.run_path(str(ROOT / 'scripts/check-repository.py'))
        lines = output.getvalue().splitlines()
        self.assertEqual([line for line in lines if line.startswith('SKIP:')],
                         ['SKIP: YAML-structure checks skipped because PyYAML is not installed'])
        for expected in ('Info.plist and privacy', 'bilingual localization',
                         'no synchronous frameQueue', 'checked-in project', 'shell script syntax'):
            self.assertTrue(any(expected in line for line in lines), expected)
        self.assertFalse(any(line.startswith('PASS: YAML') for line in lines))
        self.assertEqual({call.args[0][-1] for call in shell_checks.call_args_list},
                         {str(path) for path in (ROOT / 'scripts').glob('*.sh')})

    def test_no_codemagic_api_credential_or_query_in_ci(self):
        source = NOTIFIER.read_text() + (ROOT / 'codemagic.yaml').read_text()
        self.assertNotIn('CODEMAGIC_API_TOKEN', source)
        self.assertNotIn('api.codemagic.io', source)
        self.assertNotIn('codemagic.io/api', source)


if __name__ == '__main__':
    unittest.main()
