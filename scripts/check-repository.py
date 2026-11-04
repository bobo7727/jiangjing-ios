#!/usr/bin/env python3
"""Read-only checks that work without Xcode. These do not type-check Swift."""
import json
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ConfigurationError(ValueError):
    """The configuration violates a check or uses an unsupported layout."""


class _QuotedString(str):
    """Distinguish explicit strings from bare numeric configuration values."""


class _ConfigurationLayout:
    """Read the repository's bounded, two-space configuration layout.

    This is a text checker, not a general YAML validator. Supported structures
    are plain-key block mappings, block lists, scalar values, simple flow lists
    (e.g. [test]), and script: | bodies. Keys must be unique in each mapping.
    Quoted keys, flow mappings, anchors, aliases, tags, directives, multiline
    scalars other than scripts, and alternate indentation are rejected. Literal
    script bodies are kept separate from structural checks; artifact globs and
    punctuation inside quoted values remain ordinary data. Codemagic and
    XcodeGen remain responsible for full YAML validation.
    """

    def __init__(self, text, filename):
        self.filename = filename
        self.index = 0
        self.scripts = []
        if (any(ord(char) < 32 and char not in '\n\t' for char in text) or
                any(char in text for char in ('\x85', '\u2028', '\u2029', '\ufeff'))):
            self.fail('unsupported line ending or byte-order mark')
        self.lines = text.splitlines(keepends=True)

    def fail(self, message):
        raise ConfigurationError('{}:{}: {}'.format(
            self.filename, self.index + 1, message))

    def peek(self):
        while self.index < len(self.lines):
            line = self.lines[self.index].rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                self.index += 1
                continue
            if '\t' in line:
                self.fail('tabs are unsupported outside literal scripts')
            indent = len(line) - len(line.lstrip(' '))
            if indent % 2:
                self.fail('expected two-space indentation')
            return indent, self.without_comment(line[indent:])
        return None

    def without_comment(self, text):
        quote, index = None, 0
        while index < len(text):
            char = text[index]
            if quote == '"' and char == '\\':
                index += 2
                continue
            if quote == "'" and text[index:index + 2] == "''":
                index += 2
                continue
            if quote:
                if char == quote:
                    quote = None
            elif char == '#' and (index == 0 or text[index - 1].isspace()):
                return text[:index].rstrip()
            elif char in ('"', "'") and (index == 0 or text[index - 1] in ' [:,'):
                quote = char
            index += 1
        if quote:
            self.fail('unterminated quoted value')
        return text.rstrip()

    def scalar(self, value):
        if value.startswith('"'):
            try:
                result = json.loads(value)
            except ValueError:
                self.fail('unsupported double-quoted value')
            if not isinstance(result, str):
                self.fail('expected a quoted string')
            return _QuotedString(result)
        if value.startswith("'"):
            if not re.fullmatch(r"'(?:[^']|'')*'", value):
                self.fail('unsupported single-quoted value')
            return _QuotedString(value[1:-1].replace("''", "'"))
        if value.startswith('['):
            if not re.fullmatch(r'\[\s*(?:[\w.-]+(?:\s*,\s*[\w.-]+)*\s*)?\]', value):
                self.fail('only simple scalar flow lists are supported')
            return value
        if (any(char in value for char in '[]{}') or
                re.search(r'(^|\s)[&*!%@`>|?]|:(?:\s|$)|^-(?:\s|$)', value)):
            self.fail('unsupported scalar or YAML construct')
        return value

    def script(self, indent):
        body = []
        while self.index < len(self.lines):
            line = self.lines[self.index]
            if not line.strip():
                body.append('\n' if line.endswith('\n') else '')
                self.index += 1
                continue
            spaces = len(line) - len(line.lstrip(' '))
            if spaces <= indent:
                break
            if spaces < indent + 2:
                self.fail('unexpected literal script indentation')
            # The first nonblank line establishes YAML's literal block indent.
            if not any(part.strip() for part in body) and spaces != indent + 2:
                self.fail('literal script must start two spaces below script: |')
            body.append(line[indent + 2:])
            self.index += 1
        if not any(part.strip() for part in body):
            self.fail('empty literal script')
        result = ''.join(body).rstrip('\n') + '\n'
        self.scripts.append(result)
        return result

    def entry(self, mapping, text, indent):
        match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_.-]*):(?: +(.*))?', text)
        if not match:
            self.fail('expected a plain mapping key and colon')
        key, value = match.groups()
        if key in mapping:
            self.fail('duplicate key: ' + key)
        self.index += 1
        if key == 'script':
            if value != '|':
                self.fail('only script: | is supported')
            mapping[key] = self.script(indent)
        elif value is not None:
            mapping[key] = self.scalar(value)
        else:
            following = self.peek()
            if following is None or following[0] <= indent:
                self.fail('expected an indented mapping or list for ' + key)
            mapping[key] = self.block(indent + 2)

    def block(self, indent=0):
        first = self.peek()
        if first is None or first[0] != indent:
            self.fail('unexpected indentation')
        is_list = first[1].startswith('- ')
        result = [] if is_list else {}
        while self.peek() is not None:
            depth, text = self.peek()
            if depth < indent:
                break
            if depth != indent or text.startswith('- ') != is_list:
                self.fail('unexpected mapping/list indentation')
            if not is_list:
                self.entry(result, text, indent)
            elif re.match(r'[A-Za-z_][A-Za-z0-9_.-]*:(?: |$)', text[2:]):
                item = {}
                self.entry(item, text[2:], indent + 2)
                while self.peek() is not None and self.peek()[0] > indent:
                    depth, text = self.peek()
                    if depth != indent + 2:
                        self.fail('unexpected list mapping indentation')
                    self.entry(item, text, depth)
                result.append(item)
            else:
                result.append(self.scalar(text[2:]))
                self.index += 1
        return result


def check_configuration(codemagic_text, project_text):
    """Always check scoped configuration rules and return dedented scripts.

    Inputs must preserve line endings (open files with newline=''). No package
    imports, environment-dependent skips, or shell evaluation are needed.
    """
    workflow_layout = _ConfigurationLayout(codemagic_text, 'codemagic.yaml')
    project_layout = _ConfigurationLayout(project_text, 'project.yml')
    config = workflow_layout.block()
    project_spec = project_layout.block()

    def mapping(parent, key):
        value = parent.get(key) if isinstance(parent, dict) else None
        if not isinstance(value, dict):
            raise ConfigurationError('expected a mapping for ' + key)
        return value

    targets = mapping(project_spec, 'targets')
    app = mapping(targets, 'JiangJing')
    deployment = app.get('deploymentTarget')
    if not isinstance(deployment, _QuotedString) or deployment != '16.0':
        raise ConfigurationError('targets.JiangJing.deploymentTarget must be "16.0"')
    mapping(targets, 'JiangJingTests')
    workflows = mapping(config, 'workflows')
    simulator = mapping(workflows, 'ios-simulator')
    if any(key in simulator for key in ('publishing', 'integrations')):
        raise ConfigurationError('ios-simulator must not publish or use integrations')
    scripts = []
    for name in workflows:
        workflow = mapping(workflows, name)
        if 'triggering' in workflow:
            raise ConfigurationError(name + ' must not have triggering')
        steps = workflow.get('scripts')
        if not isinstance(steps, list) or not steps:
            raise ConfigurationError(name + ' must have a scripts list')
        for step in steps:
            if not isinstance(step, dict) or not isinstance(step.get('script'), str):
                raise ConfigurationError(name + ' requires script: | in every step')
            scripts.append(step['script'])
    if scripts != workflow_layout.scripts or project_layout.scripts:
        raise ConfigurationError('literal scripts are supported only in workflow scripts steps')
    for body in scripts:
        subprocess.run(['bash', '-n'], input=body, text=True, check=True)
    return scripts


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


def check_swift_pixel_format_key(text, filename):
    """Reject the invalid bare name, including occurrences in comments/strings."""
    for line_number, line in enumerate(text.splitlines(), 1):
        if re.search(r'\bkCVPixelFormatTypeKey\b', line):
            raise ConfigurationError('{}:{}: use kCVPixelBufferPixelFormatTypeKey'.format(
                filename, line_number))


def check_swift_pixel_format_keys():
    """Scan app and XCTest sources independently of the existing app-only checks."""
    for directory in ('JiangJing', 'JiangJingTests'):
        for source in sorted((ROOT / directory).rglob('*.swift')):
            check_swift_pixel_format_key(
                source.read_text(encoding='utf-8'), source.relative_to(ROOT))


def main():
    check_swift_pixel_format_keys()
    print('PASS: no invalid pixel-format key in app or XCTest Swift sources')
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
    with (ROOT / 'codemagic.yaml').open(encoding='utf-8', newline='') as source:
        codemagic_text = source.read()
    with (ROOT / 'project.yml').open(encoding='utf-8', newline='') as source:
        project_text = source.read()
    check_configuration(codemagic_text, project_text)
    print('PASS: scoped project/workflow configuration and embedded shell syntax')
    print('PASS: shell script syntax')


if __name__ == '__main__':
    try:
        main()
    except ConfigurationError as error:
        raise SystemExit('FAIL: ' + str(error)) from None
