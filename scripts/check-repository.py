#!/usr/bin/env python3
"""Read-only checks that work without Xcode. These do not type-check Swift."""
import json
import os
import pathlib
import plistlib
import re
import shlex
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]


class YAMLBackendUnavailable(Exception):
    """No YAML backend was found, or Ruby's require probe reports absence."""


class YAMLProcessingError(Exception):
    """A selected backend could not start or safely process the document."""


RUBY_YAML = r'''
STDIN.set_encoding(Encoding::UTF_8)
STDOUT.set_encoding(Encoding::UTF_8)
def validate(value)
  case value
  when NilClass, TrueClass, FalseClass, Integer, String
  when Float
    raise TypeError unless value.finite?
  when Array
    value.each { |item| validate(item) }
  when Hash
    value.each do |key, item|
      raise TypeError unless key.instance_of?(String)
      validate(item)
    end
  else
    raise TypeError
  end
end
begin
  data = YAML.safe_load(STDIN.read, permitted_classes: [], permitted_symbols: [],
                       aliases: false, symbolize_names: false, parse_symbols: false)
  validate(data)
  STDOUT.write(JSON.generate(data))
rescue StandardError
  exit 65
end
'''


RUBY_PROBE = '''begin
  require 'yaml'
  require 'json'
rescue LoadError => error
  STDERR.puts(error.message)
  exit 69
end'''


def reject_json_constant(_):
    raise ValueError('Non-finite JSON constant')


def ruby_environment():
    """Allow PATH shims and their default HOME configuration, without overrides.

    See docs/codemagic.md for rbenv and RubyGems' environment contracts.
    """
    environment = {'PATH': os.environ.get('PATH', os.defpath)}
    home = os.environ.get('HOME', '')
    if home and os.path.isabs(home):
        environment['HOME'] = home
    for name in ('LANG', 'LC_ALL', 'LC_CTYPE'):
        value = os.environ.get(name, '')
        if re.fullmatch(r'[^\s.]+\.UTF-?8(?:@[^\s]+)?|UTF-?8', value, re.IGNORECASE):
            environment[name] = value
    return environment


def ruby_diagnostic(phase, executable, status, stderr=b''):
    """Bound and redact metadata; only a document-free probe may expose stderr."""
    diagnostic = f'Ruby {phase} failure (executable={executable}; {status})'
    if phase == 'probe' and stderr:
        diagnostic += '; stderr: ' + stderr.decode('utf-8', errors='replace')
    secrets = {value for name, value in os.environ.items() if value and (
        name.upper().startswith('GROKBOT_') or
        re.search(r'KEY|SECRET|TOKEN|PASS(?:WORD|WD|PHRASE)?|CREDENTIAL|AUTH|COOKIE',
                  name, re.IGNORECASE))}
    if secrets:
        # A single pass also protects one-character webhook secrets without
        # reprocessing replacement markers. Redact before any output truncation.
        pattern = '|'.join(re.escape(value) for value in sorted(secrets, key=len, reverse=True))
        diagnostic = re.sub(pattern, '[REDACTED]', diagnostic)
    diagnostic = '\n'.join(diagnostic.split('\n')[:3])
    # ASCII escaping prevents terminal controls (and surrogate paths) from
    # reaching the log; the final diagnostic is at most 1 KiB, including escapes.
    diagnostic = json.dumps(diagnostic, ensure_ascii=True)[1:-1]
    return diagnostic if len(diagnostic) <= 1024 else diagnostic[:1021] + '...'


def load_yaml_text(text):
    """Prefer PyYAML; only an unavailable import permits the Ruby fallback.

    Only the document-free require probe may contribute stderr to diagnostics.
    """
    try:
        import yaml
    except ImportError:
        pass
    else:
        try:
            return yaml.safe_load(text)
        except Exception:
            raise YAMLProcessingError('PyYAML document error') from None

    environment = ruby_environment()
    executable = shutil.which('ruby', path=environment['PATH'])
    if executable is None:
        raise YAMLBackendUnavailable('PyYAML and Ruby YAML/JSON are unavailable') from None
    # Do not resolve symlinks: version-manager shims can depend on their path.
    executable = os.path.abspath(executable)
    options = dict(capture_output=True, timeout=10, env=environment)
    try:
        probe = subprocess.run([executable, '-e', RUBY_PROBE], **options)
    except subprocess.TimeoutExpired as error:
        raise YAMLProcessingError(ruby_diagnostic(
            'probe', executable, 'timeout after 10s', error.stderr)) from None
    except (OSError, subprocess.SubprocessError):
        raise YAMLProcessingError(ruby_diagnostic(
            'probe', executable, 'launch-error')) from None
    if probe.returncode != 0:
        # Only the controlled, document-free require probe signals absence.
        error_type = YAMLBackendUnavailable if probe.returncode == 69 else YAMLProcessingError
        raise error_type(ruby_diagnostic(
            'probe', executable, f'exit={probe.returncode}', probe.stderr)) from None
    try:
        result = subprocess.run([executable, '-ryaml', '-rjson', '-e', RUBY_YAML],
                                input=text.encode('utf-8'), **options)
    except subprocess.TimeoutExpired:
        raise YAMLProcessingError(ruby_diagnostic(
            'conversion', executable, 'timeout after 10s')) from None
    except (OSError, subprocess.SubprocessError):
        raise YAMLProcessingError(ruby_diagnostic(
            'conversion', executable, 'launch-error')) from None
    except UnicodeError:
        raise YAMLProcessingError(ruby_diagnostic(
            'conversion', executable, 'input encoding error')) from None
    if result.returncode != 0:
        raise YAMLProcessingError(ruby_diagnostic(
            'conversion', executable, f'exit={result.returncode}')) from None
    try:
        return json.loads(result.stdout.decode('utf-8'), parse_constant=reject_json_constant)
    except (UnicodeError, ValueError):
        raise YAMLProcessingError(ruby_diagnostic(
            'conversion', executable, 'exit=0; invalid UTF-8/JSON output')) from None


def substitution_end(source, start, backtick=False):
    """Find an expansion's end before shlex loses its quoting context."""
    index, depth, quote = start, 1, None
    while index < len(source):
        char = source[index]
        if char == "\\" and quote != "'":
            index += 2
            continue
        if backtick and char == '`':
            return index
        if quote != "'" and source.startswith('$(', index):
            index = substitution_end(source, index + 2) + 1
            continue
        if quote != "'" and char == '`' and not backtick:
            index = substitution_end(source, index + 1, backtick=True) + 1
            continue
        if char in ('"', "'"):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        elif quote is None and not backtick:
            if char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
                if depth == 0:
                    return index
        index += 1
    raise ValueError('Unterminated shell substitution')


def heredoc_expansions(body):
    """Quotes in an unquoted heredoc do not suppress command substitution."""
    expansions, index = [], 0
    while index < len(body):
        if body[index] == '\\' and body[index + 1:index + 2] in ('\\', '$', '`', '\n'):
            index += 2
            continue
        if body.startswith('$(', index) or body[index] == '`':
            backtick = body[index] == '`'
            start = index + (1 if backtick else 2)
            end = substitution_end(body, start, backtick)
            expansions.append(body[start:end])
            index = end + 1
        else:
            index += 1
    return expansions


def shell_parts(source):
    """Separate expanding substitutions and unquoted heredocs from commands.

    All unquoted heredoc bodies are scanned conservatively, even printed data.
    Quoted/escaped delimiters make bodies literal, as in the notifier's Python.
    """
    result, expansions, pending = [], [], []
    quote, index = None, 0
    while index < len(source):
        char = source[index]
        if char == "\\" and quote != "'":
            if source[index:index + 2] != "\\\n":
                result.append(source[index:index + 2])
            index += 2
            continue
        if quote != "'" and (source.startswith('$(', index) or char == '`'):
            backtick = char == '`'
            start = index + (1 if backtick else 2)
            end = substitution_end(source, start, backtick)
            expansions.append(source[start:end])
            result.append('__expansion__')
            index = end + 1
            continue
        if char in ('"', "'"):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        if quote is None and char == '#' and (index == 0 or source[index - 1].isspace()
                                              or source[index - 1] in ';|&()'):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end
            continue
        if quote is None and source.startswith('<<<', index):
            result.append('<<<')
            index += 3
            continue
        if quote is None and source.startswith('<<', index):
            match = re.match(r"<<(-?)[ \t]*", source[index:])
            start = end = index + len(match[0])
            delimiter_quote = None
            while end < len(source):
                current = source[end]
                if current == "\\" and delimiter_quote != "'":
                    end += 2
                    continue
                if current in ('"', "'"):
                    if delimiter_quote is None:
                        delimiter_quote = current
                    elif delimiter_quote == current:
                        delimiter_quote = None
                elif delimiter_quote is None and (current.isspace() or current in ';|&()<>'):
                    break
                end += 1
            raw = source[start:end]
            try:
                words = shlex.split(raw)
            except ValueError:
                words = []
            if len(words) != 1 or delimiter_quote:
                raise ValueError('Unsupported shell heredoc delimiter')
            pending.append((words[0], bool(match[1]), any(c in raw for c in "'\"\\")))
            result.append(source[index:end])
            index = end
            continue
        result.append(char)
        index += 1
        if char == '\n' and quote is None and pending:
            for delimiter, strip_tabs, literal in pending:
                body = []
                while True:
                    if index >= len(source):
                        raise ValueError('Unterminated shell heredoc')
                    end = source.find('\n', index)
                    end = len(source) if end < 0 else end + 1
                    line = source[index:end]
                    index = end
                    if (line.lstrip('\t') if strip_tabs else line).rstrip('\n') == delimiter:
                        break
                    body.append(line.lstrip('\t') if strip_tabs else line)
                if not literal:
                    text = ''.join(body)
                    expansions.append(text)
                    expansions.extend(heredoc_expansions(text))
            pending.clear()
    if pending:
        raise ValueError('Unterminated shell heredoc')
    return ''.join(result), expansions


def split_env_string(value):
    """Split literal env -S values (quotes, comments and GNU escape rules)."""
    result, word, quote, index, started = [], [], None, 0, False
    escapes = {'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
               '#': '#', '$': '$', '"': '"', "'": "'", "\\": "\\"}
    while index < len(value):
        char = value[index]
        if char == "\\" and quote != "'":
            index += 1
            if index == len(value):
                raise ValueError('Invalid shell env split-string escape')
            escaped = value[index]
            if escaped == 'c' and quote is None:
                break
            if escaped == '_':
                if quote == '"':
                    word.append(' ')
                elif started:
                    result.append(''.join(word))
                    word, started = [], False
            elif escaped in escapes:
                word.append(escapes[escaped])
                started = True
            else:
                raise ValueError('Unsupported shell env split-string escape')
        elif char in ('"', "'") and (quote is None or quote == char):
            quote = char if quote is None else None
            started = True
        elif quote is None and char.isspace():
            if started:
                result.append(''.join(word))
                word, started = [], False
        elif quote is None and char == '#' and not started:
            break
        else:
            word.append(char)
            started = True
        index += 1
    if quote:
        raise ValueError('Unterminated shell env split-string quote')
    if started:
        result.append(''.join(word))
    return result


def unwrap_shell_command(words):
    """Unwrap literal command/env/exec prefixes without inspecting arguments."""
    words = list(words)
    while words:
        while words and re.match(r'^\w+=', words[0]):
            words.pop(0)
        if not words:
            break
        command = pathlib.PurePosixPath(words[0]).name
        if command not in ('env', 'command', 'exec'):
            return words
        words.pop(0)
        while words:
            option = words[0]
            if option == '--':
                words.pop(0)
                break
            if not option.startswith('-') or option == '-':
                if command == 'env' and option == '-':
                    words.pop(0)
                break
            words.pop(0)
            if command == 'command':
                if 'v' in option or 'V' in option:
                    return []  # Lookup only, never execution.
                if not re.fullmatch(r'-p+', option):
                    return []
            elif command == 'exec':
                flags = option[1:]
                while flags:
                    flag, flags = flags[0], flags[1:]
                    if flag == 'a':
                        if not flags:
                            words = words[1:]
                        break  # The rest of this option is argv[0].
                    if flag not in 'cl':
                        return []
            elif option in ('--unset', '--chdir'):
                words = words[1:]
            elif option == '--split-string':
                words = split_env_string(words[0]) + words[1:] if words else []
            elif option.startswith('--split-string='):
                words = split_env_string(option.split('=', 1)[1]) + words
            elif (option in ('--ignore-environment', '--debug') or
                  option.startswith(('--unset=', '--chdir='))):
                pass
            elif not option.startswith('--'):
                flags = option[1:]
                while flags:
                    flag, flags = flags[0], flags[1:]
                    if flag in 'uCS':
                        value = flags if flags else (words.pop(0) if words else '')
                        if flag == 'S':
                            words = split_env_string(value) + words
                        break
                    if flag not in 'iv':
                        return []
            else:
                return []
    return []


def shell_tokens(commands):
    """Preserve literal punctuation so quoted ';' never becomes a boundary."""
    prefix = '__shell_literal__'
    while prefix in commands:
        prefix += '_'
    protected = {char: f'{prefix}{index}__' for index, char in enumerate(';&|()\n')}
    encoded, index, quote = [], 0, None
    while index < len(commands):
        char = commands[index]
        if char == '\\' and quote != "'" and index + 1 < len(commands):
            following = commands[index + 1]
            if quote is None and following in protected:
                encoded.append(protected[following])
            else:
                encoded.append(char + protected.get(following, following))
            index += 2
            continue
        if char in ('"', "'"):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        encoded.append(protected.get(char, char) if quote else char)
        index += 1
    lexer = shlex.shlex(''.join(encoded), posix=True, punctuation_chars=';&|()\n')
    lexer.whitespace = ' \t\r'
    lexer.whitespace_split = True
    lexer.commenters = ''
    try:
        tokens = list(lexer)
    except ValueError:
        raise ValueError('Cannot tokenize shell script') from None
    result = []
    for token in tokens:
        boundary = bool(token) and all(char in ';&|()\n' for char in token)
        for char, marker in protected.items():
            token = token.replace(marker, char)
        result.append((token, boundary))
    return result


def enables_shell_tracing(source):
    """Scan literal shell commands; bash/sh -c payload interpretation is excluded."""
    commands, expansions = shell_parts(source)
    if any(enables_shell_tracing(part) for part in expansions):
        return True
    tokens = shell_tokens(commands)
    try:
        if source.startswith('#!'):
            shebang = [(word, False) for word in shlex.split(source.splitlines()[0][2:])]
            tokens = shebang + [('\n', True)] + tokens
    except ValueError:
        raise ValueError('Cannot tokenize shell script') from None

    segments, segment = [], []
    for token, boundary in tokens + [('\n', True)]:
        if boundary:
            segments.append(segment)
            segment = []
        else:
            segment.append(token)
    for words in segments:
        while words and (words[0] in ('if', 'then', 'elif', 'else', 'do', '!', '{', '}')
                         or re.match(r'^\w+=', words[0])):
            words.pop(0)
        words = unwrap_shell_command(words)
        if not words:
            continue
        command = pathlib.PurePosixPath(words[0]).name
        if command not in ('set', 'bash', 'sh'):
            continue
        remaining = iter(words[1:])
        for option in remaining:
            if option == '--' or not option.startswith(('-', '+')):
                break
            if command != 'set' and option.startswith('--'):
                # Bash's argument-taking long options precede shell options.
                if option in ('--rcfile', '--init-file'):
                    next(remaining, '')
                continue
            if option.startswith('-') and not option.startswith('--') and 'x' in option[1:]:
                return True
            if command != 'set' and 'c' in option[1:]:
                break
            if option.endswith('o') or (command != 'set' and option.endswith('O')):
                setting = next(remaining, '')
                if option.startswith('-') and option.endswith('o') and setting == 'xtrace':
                    return True
    return False


MARKER_NAME = 'Mark ordinary scripts complete (best effort)'
MARKER_SCRIPT = '''if [ -n "${CM_BUILD_ID:-}" ]; then
  touch "$HOME/codemagic-success-$CM_BUILD_ID" 2>/dev/null || true
fi'''


def check_workflow_scripts(workflow_id, workflow):
    publishing_scripts = workflow['publishing']['scripts']
    assert isinstance(publishing_scripts, list) and len(publishing_scripts) == 1
    assert publishing_scripts[0] == {
        'name': 'Notify Grok Bot',
        'script': f'bash scripts/notify-grokbot.sh {workflow_id} || true'}
    marker = workflow['scripts'][-1]
    assert marker['name'] == MARKER_NAME, 'Final ordinary step must be the success marker'
    assert marker['script'].strip() == MARKER_SCRIPT, 'Success marker script must match exactly'
    for step in workflow['scripts'][:-1] + publishing_scripts:
        assert 'codemagic-success-' not in step['script'], 'Success marker referenced outside final step'
    for step in workflow['scripts'] + publishing_scripts:
        assert not enables_shell_tracing(step['script']), 'Workflow must never enable shell tracing'
        subprocess.run(['bash', '-n'], input=step['script'], text=True, check=True)


def openstep(text):
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text)
    index = 0

    def take(expected=None):
        nonlocal index
        value = tokens[index]
        index += 1
        if expected is not None:
            assert value == expected, (value, expected)
        return value

    def value():
        if tokens[index] == '{':
            take('{')
            result = {}
            while tokens[index] != '}':
                key = value()
                assert key not in result, f'Duplicate key: {key}'
                take('=')
                result[key] = value()
                take(';')
            take('}')
            return result
        if tokens[index] == '(':
            take('(')
            result = []
            while tokens[index] != ')':
                result.append(value())
                if tokens[index] != ')':
                    take(',')
            take(')')
            return result
        token = take()
        return json.loads(token) if token.startswith('"') else token

    result = value()
    assert index == len(tokens), 'Trailing OpenStep tokens'
    return result


info = plistlib.loads((ROOT / 'JiangJing/Info.plist').read_bytes())
assert info['ITSAppUsesNonExemptEncryption'] is False
permissions = ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSPhotoLibraryAddUsageDescription')
assert all(info[key].strip() for key in permissions)
assert info['UISupportedInterfaceOrientations'] == ['UIInterfaceOrientationPortrait']
privacy = plistlib.loads((ROOT / 'JiangJing/PrivacyInfo.xcprivacy').read_bytes())
assert privacy['NSPrivacyTracking'] is False
assert privacy['NSPrivacyCollectedDataTypes'] == []
print('PASS: Info.plist and privacy manifest parse; permission copy and encryption declaration present')

localizations = {}
for language in ('zh-Hans', 'en'):
    directory = ROOT / 'JiangJing/Resources' / (language + '.lproj')
    localizations[language] = openstep('{' + (directory / 'Localizable.strings').read_text() + '}')
    localized_info = openstep('{' + (directory / 'InfoPlist.strings').read_text() + '}')
    assert all(localized_info[key].strip() for key in permissions)
    assert localized_info['CFBundleDisplayName'].strip()
assert localizations['en'].keys() == localizations['zh-Hans'].keys()
keys = set(re.findall(r'String\(localized: "([^"]+)"', (ROOT / 'JiangJing/Support/L10n.swift').read_text()))
assert keys == set(localizations['en']), (keys ^ set(localizations['en']))
members = set(re.findall(r'static var (\w+): String', (ROOT / 'JiangJing/Support/L10n.swift').read_text()))
for source in (ROOT / 'JiangJing').rglob('*.swift'):
    text = source.read_text()
    assert not re.search(r'\bframeQueue\s*\.\s*sync\b', text), (source, 'Synchronous frame-queue wait')
    uses = set(re.findall(r'L10n\.(\w+)', text))
    assert uses <= members, (source, uses - members)
for path in (ROOT / 'JiangJing/Resources/Assets.xcassets').rglob('Contents.json'):
    json.loads(path.read_text())
print('PASS: bilingual localization keys, L10n references, permission strings and asset JSON')
print('PASS: no synchronous frameQueue waits in app sources')

project = openstep((ROOT / 'JiangJing.xcodeproj/project.pbxproj').read_text())
objects = project['objects']
paths = {}

def visit(object_id, parent):
    entry = objects[object_id]
    path = parent / entry.get('path', '')
    paths[object_id] = path
    if entry['isa'] in ('PBXGroup', 'PBXVariantGroup'):
        for child in entry.get('children', []):
            visit(child, path)

visit(objects[project['rootObject']]['mainGroup'], ROOT)
for item in objects.values():
    for key in ('fileRef', 'productReference', 'target', 'targetProxy', 'containerPortal', 'buildConfigurationList'):
        if key in item:
            assert item[key] in objects, (key, item[key])
    for key in ('children', 'buildPhases', 'dependencies', 'targets', 'buildConfigurations', 'files'):
        for reference in item.get(key, []):
            assert reference in objects, (key, reference)
for target in (o for o in objects.values() if o['isa'] == 'PBXNativeTarget'):
    source_paths = set()
    for phase_id in target['buildPhases']:
        phase = objects[phase_id]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            for build_id in phase['files']:
                source_paths.add(paths[objects[build_id]['fileRef']])
    expected = set((ROOT / target['name']).rglob('*.swift'))
    assert source_paths == expected, (target['name'], expected - source_paths, source_paths - expected)
for reference in ET.parse(ROOT / 'JiangJing.xcodeproj/xcshareddata/xcschemes/JiangJing.xcscheme').iter('BuildableReference'):
    assert objects[reference.attrib['BlueprintIdentifier']]['name'] == reference.attrib['BlueprintName']
print('PASS: checked-in project object references, app/test source membership and shared scheme')

for path in (ROOT / 'scripts').glob('*.sh'):
    subprocess.run(['bash', '-n', str(path)], check=True)
notifier = ROOT / 'scripts/notify-grokbot.sh'
assert notifier.is_file(), 'Grok Bot notifier missing'
assert not enables_shell_tracing(notifier.read_text()), 'Notifier must never enable shell tracing'
assert notifier.read_text().splitlines()[1] == 'set +x', 'Disable inherited tracing first'


def assert_repository_yaml(config, project_spec):
    """Shared structural checks, independent of the YAML backend."""
    assert project_spec['targets']['JiangJing']['deploymentTarget'] == '16.0'
    assert 'JiangJingTests' in project_spec['targets']
    compile_workflow = config['workflows']['ios-simulator']
    assert 'integrations' not in compile_workflow
    assert compile_workflow['environment'] == {'xcode': '26.6', 'groups': ['grokbot_notify']}
    assert set(compile_workflow['publishing']) == {'scripts'}, 'Simulator allows only the notifier'
    release_workflow = config['workflows']['ios-testflight']
    assert release_workflow['environment']['groups'] == ['jiangjing_release', 'grokbot_notify']
    assert release_workflow['integrations'] == {'app_store_connect': 'stl2stp-app-store-connect'}
    assert release_workflow['environment']['ios_signing'] == {
        'distribution_type': 'app_store', 'bundle_identifier': 'com.jiangjing.magnifier'}
    assert set(release_workflow['publishing']) == {'app_store_connect', 'scripts'}
    assert release_workflow['publishing']['app_store_connect'] == {
        'auth': 'integration', 'submit_to_testflight': False, 'submit_to_app_store': False}
    for workflow_id, workflow in config['workflows'].items():
        assert 'triggering' not in workflow
        assert workflow['environment']['xcode'] == '26.6'
        check_workflow_scripts(workflow_id, workflow)


def check_repository_yaml():
    documents = []
    for filename in ('codemagic.yaml', 'project.yml'):
        try:
            documents.append(load_yaml_text((ROOT / filename).read_text(encoding='utf-8')))
        except YAMLBackendUnavailable as error:
            if 'CI' in os.environ or 'CM_BUILD_ID' in os.environ:
                raise SystemExit(f'FAIL: {filename}: {error}; YAML checks are required in CI') from None
            print(f'SKIP: YAML-structure checks: {error} (local run only)')
            return
        except YAMLProcessingError as error:
            raise SystemExit(f'FAIL: {filename}: {error}') from None
    assert_repository_yaml(*documents)
    print('PASS: YAML and embedded shell syntax; simulator only notifies; release settings preserved')


check_repository_yaml()
print('PASS: shell script syntax')
