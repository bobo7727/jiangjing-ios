#!/usr/bin/env python3
"""Read-only checks that work without Xcode. These do not type-check Swift."""
import json
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]


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
try:
    import yaml
except ImportError:
    print('SKIP: YAML parser unavailable (Codemagic itself validates workflow YAML)')
else:
    config = yaml.safe_load((ROOT / 'codemagic.yaml').read_text())
    project_spec = yaml.safe_load((ROOT / 'project.yml').read_text())
    assert project_spec['targets']['JiangJing']['deploymentTarget'] == '16.0'
    assert 'JiangJingTests' in project_spec['targets']
    compile_workflow = config['workflows']['ios-simulator']
    assert 'publishing' not in compile_workflow and 'integrations' not in compile_workflow
    for workflow in config['workflows'].values():
        assert 'triggering' not in workflow
        for step in workflow['scripts']:
            subprocess.run(['bash', '-n'], input=step['script'], text=True, check=True)
    print('PASS: project/workflow YAML parses, embedded shell syntax, compile workflow has no publishing')
print('PASS: shell script syntax')
