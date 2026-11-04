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


ROOT = Path(__file__).resolve().parents[1]
NOTIFIER = ROOT / 'scripts/notify-grokbot.sh'


def load_checker():
    with mock.patch.dict(os.environ), contextlib.redirect_stdout(io.StringIO()):
        os.environ.pop('CI', None)
        os.environ.pop('CM_BUILD_ID', None)
        return runpy.run_path(str(ROOT / 'scripts/check-repository.py'))


@contextlib.contextmanager
def without_pyyaml():
    original_import = builtins.__import__

    def without_yaml(name, *args, **kwargs):
        if name == 'yaml':
            raise ImportError('simulated missing PyYAML')
        return original_import(name, *args, **kwargs)

    with mock.patch('builtins.__import__', side_effect=without_yaml):
        yield

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
    @classmethod
    def setUpClass(cls):
        cls.checker = load_checker()

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

    def test_yaml_marker_is_last_best_effort_and_skipped_after_script_failure(self):
        try:
            workflows = self.checker['load_yaml_text']((ROOT / 'codemagic.yaml').read_text())['workflows']
        except self.checker['YAMLBackendUnavailable']:
            self.skipTest('Neither PyYAML nor Ruby YAML/JSON is available')
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
        (ROOT / '.build/notification-tests').mkdir(parents=True, exist_ok=True)
        cls.checker = load_checker()

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
                       "python3 -c 'print(\"set -x\")'", 'echo "<<EOF"',
                       'cat <<<"set -x"', 'echo ok;# bash -x script\nset +x',
                       'echo ok # bash -x script\nset +x'):
            with self.subTest(source=source):
                self.assertFalse(guard(source))

    def test_trace_guard_reports_tokenization_errors(self):
        for source in ("echo 'unclosed", "cat <<'EOF'\nmissing delimiter"):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, 'shell'):
                self.checker['enables_shell_tracing'](source)

    def test_trace_guard_wrappers_substitutions_and_unquoted_heredocs(self):
        positive = (
            'env bash -x script', '/usr/bin/env bash -x script',
            'command bash -x script', 'exec bash -x script',
            'env -i TOKEN=-x bash -eux script', 'env -u TOKEN -C /tmp bash -o xtrace script',
            'env --unset=TOKEN --chdir=/tmp -- bash -x script',
            'env -uTOKEN -C/tmp bash -x script',
            'env -iu TOKEN bash -x script', "env -iS 'bash -x' script",
            'env --debug bash -x script', 'exec -claNAME bash -x script',
            'exec -a name -c -l command -p env FLAG=value /bin/sh -ex script',
            'command -- exec -- env -- bash -x script',
            "env -S 'bash -eux' script", "env --split-string='sh -o xtrace' script",
            "env -S'bash -x' script", r"env -S 'bash\_-x' script",
            'env -S \'bash "-x"\' script',
            'echo "$(env bash -x script)"', 'echo $(command sh -o xtrace script)',
            'VALUE=$(exec bash -x script)', 'echo "$(echo $(sh -x script))"',
            'echo `bash -x script`', 'echo "`env sh -x script`"',
            'cat <<EOF\nbash -x script\nEOF\n',
            'cat <<-EOF\n\tsh -x script\n\tEOF\nset +o xtrace',
            'cat <<EOF\n$(bash -x script)\nEOF\n',
            'cat <<EOF\n\'$(bash -x script)\'\nEOF\n',
            'cat <<EOF\n\'`bash -x script`\'\nEOF\n',
            "cat <<'LITERAL' <<RAW\nsh -x ignored\nLITERAL\nexec bash -x script\nRAW\n",
        )
        negative = (
            'env bash script -x', 'env VALUE=-x bash script',
            'env -u -x bash script', 'env -C -x bash script',
            'command -v bash -x', 'command -V bash -x', 'command -pv bash -x',
            'exec -a -x bash script', 'exec -c -l bash -- script -x',
            'exec -a-x bash script', 'env -iu -x bash script',
            "env -S 'bash script -x'", "env -S 'bash -- script -x'",
            "env -S 'bash # -x'", r"env -S 'bash\c -x'",
            'echo \'$(bash -x script)\'', 'echo \'`bash -x script`\'',
            r'echo "\$(bash -x script)"', r'echo \`bash -x script\`',
            'echo "$(printf \'%s\' \'bash -x script\')"',
            'cat <<"EOF"\nbash -x script\nEOF\n',
            'cat <<\\EOF\nbash -x script\nEOF\n',
            'cat <<E"O"F\nbash -x script\nEOF\n',
            "cat <<E'O'F\nbash -x script\nEOF\n",
            'cat <<-\\EOF\n\tsh -x script\n\tEOF\n',
            "cat <<'ONE' <<'TWO'\nsh -x script\nONE\nbash -x script\nTWO\n",
            'env bash +x script', 'command set +o xtrace',
            'bash -c \'echo literal\' -x', 'bash --rcfile -x script',
            'echo ";" bash -x script', "echo ';' bash -x script",
            'echo "\n" bash -x script', r'echo \; bash -x script',
        )
        for expected, sources in ((True, positive), (False, negative)):
            for source in sources:
                with self.subTest(source=source):
                    self.assertIs(self.checker['enables_shell_tracing'](source), expected)

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

    def repository_documents(self):
        simulator = self.workflow()
        simulator['environment'] = {'xcode': '26.6', 'groups': ['grokbot_notify']}
        release = self.workflow('ios-testflight')
        release['environment'] = {
            'xcode': '26.6', 'groups': ['jiangjing_release', 'grokbot_notify'],
            'ios_signing': {'distribution_type': 'app_store',
                            'bundle_identifier': 'com.jiangjing.magnifier'}}
        release['integrations'] = {'app_store_connect': 'stl2stp-app-store-connect'}
        release['publishing']['app_store_connect'] = {
            'auth': 'integration', 'submit_to_testflight': False, 'submit_to_app_store': False}
        return ({'workflows': {'ios-simulator': simulator, 'ios-testflight': release}},
                {'targets': {'JiangJing': {'deploymentTarget': '16.0'}, 'JiangJingTests': {}}})

    def test_pyyaml_preferred_and_parse_failure_never_retries_ruby(self):
        loader = self.checker['load_yaml_text']
        fake_yaml = mock.Mock()
        fake_yaml.safe_load.return_value = {'yes': True}
        with mock.patch.dict(sys.modules, yaml=fake_yaml), mock.patch('subprocess.run') as ruby:
            self.assertEqual(loader('anything'), {'yes': True})
            fake_yaml.safe_load.assert_called_once_with('anything')
            ruby.assert_not_called()
            fake_yaml.safe_load.side_effect = ValueError('secret document content')
            with self.assertRaisesRegex(self.checker['YAMLProcessingError'], '^PyYAML document error$'):
                loader('private input')
            ruby.assert_not_called()

    def test_ruby_fallback_uses_stdin_utf8_and_minimal_environment(self):
        calls = []

        def ruby(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, b'{"enabled":true,"version":"16.0"}', b'')

        environment = {'PATH': 'relative/bin', 'HOME': '/home/build', 'LANG': 'C.UTF-8',
                       'LC_CTYPE': 'en_US.utf8', 'LC_ALL': 'C',
                       'GROKBOT_WEBHOOK_KEY': 'secret', 'RUBYOPT': '-rprivate',
                       'RUBYLIB': '/private', 'BUNDLE_GEMFILE': '/private'}
        with without_pyyaml(), mock.patch('subprocess.run', side_effect=ruby), \
                mock.patch('shutil.which', return_value='relative/bin/ruby') as which, \
                mock.patch.dict(os.environ, environment, clear=True):
            self.assertEqual(self.checker['load_yaml_text']('enabled: YES # 文本'),
                             {'enabled': True, 'version': '16.0'})
        which.assert_called_once_with('ruby', path='relative/bin')
        executable = os.path.abspath('relative/bin/ruby')
        self.assertEqual(len(calls), 2)
        for command, options in calls:
            self.assertEqual(command[0], executable)
            self.assertNotIn('enabled: YES # 文本', command)
            self.assertEqual(options['env'], {'PATH': 'relative/bin', 'HOME': '/home/build',
                                              'LANG': 'C.UTF-8', 'LC_CTYPE': 'en_US.utf8'})
            for option in ('encoding', 'errors', 'text', 'shell'):
                self.assertNotIn(option, options)
            self.assertEqual(options['timeout'], 10)
            self.assertTrue(options['capture_output'])
        self.assertIs(calls[0][1]['env'], calls[1][1]['env'])
        self.assertNotIn('input', calls[0][1])
        self.assertEqual(calls[0][0], [executable, '-e', self.checker['RUBY_PROBE']])
        self.assertEqual(calls[1][0][:4], [executable, '-ryaml', '-rjson', '-e'])
        self.assertEqual(calls[1][1]['input'], 'enabled: YES # 文本'.encode('utf-8'))
        program = calls[1][0][-1]
        for setting in ('YAML.safe_load', 'permitted_classes: []', 'permitted_symbols: []',
                        'aliases: false', 'symbolize_names: false', 'parse_symbols: false'):
            self.assertIn(setting, program)

    def test_ruby_environment_defaults_and_locale_allowlist(self):
        for home in ('', 'relative/home', '/home/build'):
            for locale in ('', 'C', 'en_US', 'en_US.ISO-8859-1', 'not-UTF-8',
                           'en_US.UTF-8\nRUBYOPT=x', 'C.UTF-8', 'en_US.utf8',
                           'UTF-8', 'zh_CN.UTF-8@variant'):
                with self.subTest(home=home, locale=locale), mock.patch.dict(
                        os.environ, {'HOME': home, 'LANG': locale, 'LC_ALL': locale,
                                     'LC_CTYPE': locale}, clear=True):
                    expected = {'PATH': os.defpath}
                    if home == '/home/build':
                        expected['HOME'] = home
                    if locale in ('C.UTF-8', 'en_US.utf8', 'UTF-8', 'zh_CN.UTF-8@variant'):
                        expected.update(dict.fromkeys(('LANG', 'LC_ALL', 'LC_CTYPE'), locale))
                    self.assertEqual(self.checker['ruby_environment'](), expected)
        with mock.patch.dict(os.environ, {'PATH': ''}, clear=True):
            self.assertEqual(self.checker['ruby_environment'](), {'PATH': ''})

    def test_executable_stub_receives_only_allowlist_and_preserves_symlink(self):
        # Use actual executable lookup and subprocesses, even on Ruby-free hosts.
        with tempfile.TemporaryDirectory(dir=ROOT / '.build/notification-tests') as directory:
            directory = Path(directory)
            record = directory / 'ruby.jsonl'
            target = directory / 'ruby-shim'
            target.write_text('#!' + sys.executable + '\n' +
                              'import json, os, sys\n' +
                              f'with open({str(record)!r}, "a") as stream:\n' +
                              '    stream.write(json.dumps({"argv": sys.argv, "env": dict(os.environ), '
                              '"input": sys.stdin.read()}) + "\\n")\n' +
                              'print(\'{"enabled": true}\')\n')
            target.chmod(0o700)
            executable = directory / 'ruby'
            executable.symlink_to(target)
            environment = {'PATH': os.path.relpath(directory), 'HOME': str(directory),
                           'LANG': 'C.UTF-8', 'LC_ALL': 'en_US.UTF-8', 'LC_CTYPE': 'UTF-8'}
            excluded = {'GROKBOT_WEBHOOK_KEY': 'q', 'GROKBOT_WEBHOOK_URL': 'https://private',
                        'GROKBOT_OTHER': 'private', 'GEM_HOME': '/private', 'GEM_PATH': '/private',
                        'GEMRC': '/private', 'GEM_REQUIREMENT_JSON': 'invalid',
                        'RBENV_ROOT': '/private', 'RBENV_VERSION': 'invalid',
                        'RBENV_HOOK_PATH': '/private', 'RBENV_DIR': '/private',
                        'RBENV_DEBUG': '1', 'BUNDLE_GEMFILE': '/private',
                        'RUBYOPT': '-rprivate', 'RUBYLIB': '/private',
                        'RUBYGEMS_GEMDEPS': '-', 'BASH_ENV': '/private', 'ENV': '/private',
                        'AWS_ACCESS_KEY_ID': 'credential', 'CM_BUILD_ID': 'release',
                        'UNRELATED': 'private'}
            with without_pyyaml(), mock.patch.dict(os.environ, {**environment, **excluded}, clear=True):
                self.assertEqual(self.checker['load_yaml_text']('enabled: YES # 文本'), {'enabled': True})
            calls = [json.loads(line) for line in record.read_text().splitlines()]
            self.assertEqual(len(calls), 2)
            for call in calls:
                self.assertEqual(call['argv'][0], str(executable))
                self.assertEqual(call['env'], environment)
                self.assertFalse(set(call['env']) & set(excluded))
            self.assertEqual(calls[0]['input'], '')
            self.assertEqual(calls[1]['input'], 'enabled: YES # 文本')

    def test_ruby_availability_is_distinct_from_processing_failure(self):
        success = subprocess.CompletedProcess([], 0, b'', b'')
        cases = [
            ([FileNotFoundError('private')], 'YAMLProcessingError'),
            ([subprocess.CompletedProcess([], 69, b'', b'cannot load yaml')],
             'YAMLBackendUnavailable'),
            ([subprocess.CompletedProcess([], 1, b'', b'unexpected LoadError')], 'YAMLProcessingError'),
            ([PermissionError('private')], 'YAMLProcessingError'),
            ([subprocess.CompletedProcess([], 2, b'private', b'probe error')], 'YAMLProcessingError'),
            ([subprocess.TimeoutExpired('private', 10)], 'YAMLProcessingError'),
            ([success, subprocess.CompletedProcess([], 65, b'private', b'private')], 'YAMLProcessingError'),
            ([success, subprocess.CompletedProcess([], 0, b'private invalid JSON', b'')], 'YAMLProcessingError'),
            ([success, subprocess.CompletedProcess([], 0, b'NaN', b'')], 'YAMLProcessingError'),
            ([success, subprocess.CompletedProcess([], 0, b'{"value":"\xff"}', b'')], 'YAMLProcessingError'),
            ([success, subprocess.TimeoutExpired('private', 10)], 'YAMLProcessingError'),
            ([success, OSError('private')], 'YAMLProcessingError'),
            ([success, FileNotFoundError('private')], 'YAMLProcessingError'),
            ([success, subprocess.SubprocessError('private')], 'YAMLProcessingError'),
        ]
        for effects, error_type in cases:
            with self.subTest(effects=effects), without_pyyaml(), \
                    mock.patch('shutil.which', return_value='/test/bin/ruby'), \
                    mock.patch('subprocess.run', side_effect=effects), \
                    self.assertRaises(self.checker[error_type]) as raised:
                self.checker['load_yaml_text']('private YAML')
            self.assertNotIn('private', str(raised.exception))

    def test_missing_ruby_lookup_does_not_launch(self):
        with without_pyyaml(), mock.patch('shutil.which', return_value=None), \
                mock.patch('subprocess.run') as run, \
                self.assertRaises(self.checker['YAMLBackendUnavailable']):
            self.checker['load_yaml_text']('private YAML')
        run.assert_not_called()

    def test_probe_diagnostics_include_metadata_and_safe_stderr(self):
        cases = [
            (subprocess.CompletedProcess([], 1, b'private YAML', b'cannot start\nsecond\nthird\nfourth'),
             'YAMLProcessingError', 'exit=1', ('cannot start', 'second', 'third')),
            (subprocess.CompletedProcess([], 69, b'private YAML', b'cannot load yaml\n\xff'),
             'YAMLBackendUnavailable', 'exit=69', ('cannot load yaml', r'\ufffd')),
            (subprocess.TimeoutExpired('private YAML', 10, output=b'private YAML', stderr=b'waiting'),
             'YAMLProcessingError', 'timeout after 10s', ('waiting',)),
            (FileNotFoundError('private YAML'), 'YAMLProcessingError', 'launch-error', ()),
            (PermissionError('private YAML'), 'YAMLProcessingError', 'launch-error', ()),
        ]
        for result, error_type, status, details in cases:
            with self.subTest(result=result), without_pyyaml(), \
                    mock.patch('shutil.which', return_value='/test/bin/ruby'), \
                    mock.patch.dict(os.environ, {}, clear=True), \
                    mock.patch('subprocess.run', side_effect=[result]), \
                    self.assertRaises(self.checker[error_type]) as raised:
                self.checker['load_yaml_text']('private YAML')
            diagnostic = str(raised.exception)
            for expected in ('Ruby probe failure', 'executable=/test/bin/ruby', status, *details):
                self.assertIn(expected, diagnostic)
            self.assertNotIn('fourth', diagnostic)
            self.assertNotIn('private YAML', diagnostic)
            self.assertTrue(raised.exception.__suppress_context__)

    def test_conversion_diagnostics_never_expose_output_or_exception_details(self):
        cases = [
            (subprocess.CompletedProcess([], 65, b'private YAML stdout', b'private YAML stderr'), 'exit=65'),
            (subprocess.CompletedProcess([], 0, b'private YAML JSON error', b'private YAML stderr'), 'exit=0'),
            (subprocess.CompletedProcess([], 0, b'{"value":"\xff"}', b'private YAML stderr'), 'exit=0'),
            (subprocess.TimeoutExpired('private YAML', 10, output=b'private YAML stdout',
                                       stderr=b'private YAML stderr'), 'timeout after 10s'),
            (OSError('private YAML'), 'launch-error'),
        ]
        for result, status in cases:
            with self.subTest(result=result), without_pyyaml(), \
                    mock.patch('shutil.which', return_value='/test/bin/ruby'), \
                    mock.patch.dict(os.environ, {}, clear=True), \
                    mock.patch('subprocess.run', side_effect=[
                        subprocess.CompletedProcess([], 0, b'', b''), result]), \
                    self.assertRaises(self.checker['YAMLProcessingError']) as raised:
                self.checker['load_yaml_text']('private YAML')
            self.assertEqual(str(raised.exception),
                             'Ruby conversion failure (executable=/test/bin/ruby; ' + status +
                             ('; invalid UTF-8/JSON output' if status == 'exit=0' else '') + ')')
            self.assertTrue(raised.exception.__suppress_context__)

    def test_diagnostics_redact_before_line_and_byte_limits_and_escape_controls(self):
        environment = {'GROKBOT_WEBHOOK_KEY': 'q', 'GROKBOT_WEBHOOK_URL': 'https://webhook-secret',
                       'GROKBOT_OTHER': 'overlap', 'API_TOKEN': 'overlap-long',
                       'AWS_SECRET_ACCESS_KEY': 'path-secret', 'DATABASE_PASSWORD': 'line\nsecret'}
        stderr = b'q https://webhook-secret overlap-long overlap line\nsecret\nsecond\x1b\t\r\x00\nthird\nfourth'
        with mock.patch.dict(os.environ, environment, clear=True):
            diagnostic = self.checker['ruby_diagnostic'](
                'probe', '/path-secret/ruby', 'exit=1', stderr)
            bounded = self.checker['ruby_diagnostic'](
                'probe', '/path-secret/ruby', 'exit=1', b'a' * 950 + b'overlap-long' * 30)
        for value in environment.values():
            self.assertNotIn(value, diagnostic)
            self.assertNotIn(value, bounded)
        self.assertIn('executable=/[REDACTED]/ruby', diagnostic)
        self.assertNotIn('[REDACTED]-long', diagnostic)
        self.assertIn(r'second\u001b\t\r\u0000', diagnostic)
        self.assertNotIn('fourth', diagnostic)
        self.assertTrue(all(32 <= ord(char) < 127 for char in diagnostic))
        self.assertLessEqual(len(bounded.encode('utf-8')), 1024)
        self.assertTrue(bounded.endswith('...'))
        self.assertIn('[REDACTED]', bounded)
        self.assertIn('STDERR.puts(error.message)', self.checker['RUBY_PROBE'])
        self.assertNotIn('--disable-gems', self.checker['RUBY_PROBE'])

    def run_mocked_ruby_checker(self, documents):
        actual_run = subprocess.run
        embedded_checks = []
        output = io.StringIO()
        texts = [(ROOT / filename).read_text() for filename in ('codemagic.yaml', 'project.yml')]

        def dispatch(command, **kwargs):
            if command[0] == '/test/bin/ruby':
                result = (json.dumps(documents[texts.index(kwargs['input'].decode('utf-8'))])
                          if 'input' in kwargs else '')
                return subprocess.CompletedProcess(command, 0, result.encode('utf-8'), b'')
            self.assertEqual(command[:2], ['bash', '-n'])
            if 'input' in kwargs:
                embedded_checks.append(kwargs['input'])
                kwargs['capture_output'] = True
            return actual_run(command, **kwargs)

        with mock.patch.dict(os.environ, CI='1'), without_pyyaml(), \
                mock.patch('shutil.which', return_value='/test/bin/ruby'), \
                mock.patch('subprocess.run', side_effect=dispatch), contextlib.redirect_stdout(output):
            runpy.run_path(str(ROOT / 'scripts/check-repository.py'))
        return embedded_checks, output.getvalue()

    def test_mocked_ruby_runs_full_structure_and_embedded_syntax_checks(self):
        scripts, output = self.run_mocked_ruby_checker(self.repository_documents())
        self.assertEqual(len(scripts), 6)
        self.assertIn('PASS: YAML and embedded shell syntax', output)
        self.assertNotIn('SKIP:', output)

    def test_mocked_ruby_rejects_all_structural_contract_regressions(self):
        # Mutate one contract at a time; all run through Ruby JSON and the CLI.
        mutations = [
            (('workflows', 'ios-simulator', 'scripts', -1, 'name'), 'wrong'),
            (('workflows', 'ios-simulator', 'scripts', -1, 'script'), 'true'),
            (('workflows', 'ios-simulator', 'environment', 'xcode'), 'other'),
            (('workflows', 'ios-testflight', 'environment', 'xcode'), 'other'),
            (('workflows', 'ios-simulator', 'environment', 'groups'), []),
            (('workflows', 'ios-testflight', 'environment', 'groups'), []),
            (('workflows', 'ios-testflight', 'environment', 'ios_signing', 'distribution_type'), 'other'),
            (('workflows', 'ios-testflight', 'integrations', 'app_store_connect'), 'other'),
            (('workflows', 'ios-testflight', 'publishing', 'app_store_connect', 'auth'), 'other'),
            (('workflows', 'ios-testflight', 'publishing', 'app_store_connect', 'submit_to_testflight'), True),
            (('workflows', 'ios-testflight', 'publishing', 'app_store_connect', 'submit_to_app_store'), True),
            (('workflows', 'ios-simulator', 'publishing', 'scripts', 0, 'script'), 'false'),
            (('workflows', 'ios-testflight', 'scripts', 0, 'script'), 'env bash -x script'),
            (('workflows', 'ios-simulator', 'integrations'), {}),
            (('workflows', 'ios-simulator', 'triggering'), {}),
            (('workflows', 'ios-testflight', 'triggering'), {}),
            (('workflows', 'ios-simulator', 'publishing', 'app_store_connect'), {}),
            (('workflows', 'ios-testflight', 'publishing', 'extra'), {}),
        ]
        for path, value in mutations:
            with self.subTest(path=path):
                documents = self.repository_documents()
                target = documents[0]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(AssertionError):
                    self.run_mocked_ruby_checker(documents)
        documents = self.repository_documents()
        documents[0]['workflows']['ios-testflight']['scripts'][0]['script'] = 'if then'
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_mocked_ruby_checker(documents)
        for project in ({'targets': {'JiangJing': {'deploymentTarget': '15.0'}, 'JiangJingTests': {}}},
                        {'targets': {'JiangJing': {'deploymentTarget': '16.0'}}}):
            with self.assertRaises(AssertionError):
                self.run_mocked_ruby_checker((self.repository_documents()[0], project))

    def test_cli_backend_policy_with_explicit_subprocess_environments(self):
        # -S simulates absent PyYAML. A bash-only PATH makes Ruby absence deterministic.
        with tempfile.TemporaryDirectory(dir=ROOT / '.build/notification-tests') as directory:
            Path(directory, 'bash').symlink_to('/bin/bash')
            for additions in ({}, {'CI': '1'}, {'CI': ''}, {'CM_BUILD_ID': 'build'}, {'CM_BUILD_ID': ''}):
                environment = {'PATH': directory, **additions}
                result = subprocess.run([sys.executable, '-B', '-S', 'scripts/check-repository.py'],
                                        cwd=ROOT, env=environment, capture_output=True, text=True)
                with self.subTest(environment=additions):
                    self.assertNotIn('PASS: YAML', result.stdout)
                    if additions:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('YAML checks are required in CI', result.stderr)
                        self.assertIn('codemagic.yaml', result.stderr)
                        self.assertNotIn('SKIP:', result.stdout)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.count('SKIP:'), 1)
                        self.assertIn('PASS: shell script syntax', result.stdout)

    def test_cli_local_skip_omits_only_yaml_and_embedded_checks(self):
        actual_run = subprocess.run
        shell_checks, output = [], io.StringIO()

        def dispatch(command, **kwargs):
            shell_checks.append((command, kwargs))
            return actual_run(command, **kwargs)

        with mock.patch.dict(os.environ), without_pyyaml(), \
                mock.patch('shutil.which', return_value=None), \
                mock.patch('subprocess.run', side_effect=dispatch), contextlib.redirect_stdout(output):
            os.environ.pop('CI', None)
            os.environ.pop('CM_BUILD_ID', None)
            runpy.run_path(str(ROOT / 'scripts/check-repository.py'))
        self.assertEqual({command[-1] for command, _ in shell_checks},
                         {str(path) for path in (ROOT / 'scripts').glob('*.sh')})
        self.assertTrue(all('input' not in options for _, options in shell_checks))
        for expected in ('Info.plist and privacy', 'bilingual localization',
                         'no synchronous frameQueue', 'checked-in project', 'shell script syntax'):
            self.assertIn(expected, output.getvalue())
        self.assertEqual(output.getvalue().count('SKIP:'), 1)
        self.assertNotIn('PASS: YAML', output.getvalue())

    def test_cli_document_errors_fail_locally_and_in_ci_without_parser_details(self):
        namespace = self.checker['check_repository_yaml'].__globals__
        for environment in ({}, {'CI': ''}):
            for error in ('Ruby document/conversion error', 'Ruby processing/JSON error',
                          'Ruby startup failure', 'PyYAML document error'):
                output = io.StringIO()
                with self.subTest(environment=environment, error=error), \
                        mock.patch.dict(os.environ, environment, clear=True), \
                        mock.patch.dict(namespace, load_yaml_text=mock.Mock(
                            side_effect=self.checker['YAMLProcessingError'](error))), \
                        contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as raised:
                    self.checker['check_repository_yaml']()
                self.assertEqual(str(raised.exception), f'FAIL: codemagic.yaml: {error}')
                self.assertEqual(output.getvalue(), '')

    def ruby_load(self, text):
        with without_pyyaml():
            try:
                return self.checker['load_yaml_text'](text)
            except self.checker['YAMLBackendUnavailable']:
                self.skipTest('Ruby with YAML/JSON is not available locally')

    def assert_same_types_and_values(self, left, right):
        self.assertIs(type(left), type(right))
        if isinstance(left, dict):
            self.assertEqual(left.keys(), right.keys())
            for key in left:
                self.assertIs(type(key), str)
                self.assert_same_types_and_values(left[key], right[key])
        elif isinstance(left, list):
            self.assertEqual(len(left), len(right))
            for a, b in zip(left, right):
                self.assert_same_types_and_values(a, b)
        else:
            self.assertEqual(left, right)

    def test_live_ruby_matches_pyyaml_types_and_values(self):
        try:
            import yaml
        except ImportError:
            self.skipTest('PyYAML is unavailable for live equivalence comparison')
        texts = [(ROOT / filename).read_text() for filename in ('codemagic.yaml', 'project.yml')]
        texts.append('yes_value: YES\nno_value: NO\nquoted: "YES"\nversion: "16.0"\n'
                     'integer: 42\nboolean: false\nfloat: 1.25\nnull_value: null\n'
                     'symbol_text: :name\nblock: |\n  line one\n  line two\n')
        for text in texts:
            self.assert_same_types_and_values(yaml.safe_load(text), self.ruby_load(text))

    def test_live_ruby_rejects_unsafe_or_non_json_yaml(self):
        self.ruby_load('probe: true')
        for text in ('a: &anchor value\nb: *anchor', 'value: !ruby/symbol name',
                     'value: !ruby/object:Object {}', 'value: 2026-11-04',
                     'value: 2026-11-04T12:00:00Z', '1: value', 'true: value',
                     'value: .inf', 'value: .nan', 'broken: ['):
            with self.subTest(text=text), without_pyyaml(), \
                    self.assertRaises(self.checker['YAMLProcessingError']):
                self.checker['load_yaml_text'](text)

    def test_no_codemagic_api_credential_or_query_in_ci(self):
        source = NOTIFIER.read_text() + (ROOT / 'codemagic.yaml').read_text()
        self.assertNotIn('CODEMAGIC_API_TOKEN', source)
        self.assertNotIn('api.codemagic.io', source)
        self.assertNotIn('codemagic.io/api', source)


if __name__ == '__main__':
    unittest.main()
