#!/usr/bin/env python3
"""Localization completeness checks. Stdlib only; run from anywhere, no Xcode needed.

Policy: English is the development/fallback language. Any Chinese system language
(Simplified or Traditional) shows Chinese; every other language shows English.
"""
import importlib.util
import pathlib
import plistlib
import re
import sys

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parents[1]
RES = ROOT / 'JiangJing/Resources'
LANGUAGES = ('en', 'zh-Hans', 'zh-Hant')
CJK = re.compile('[⺀-⿟　-〿぀-ヿ㐀-䶿一-鿿豈-﫿＀-￯]')
HAN = re.compile('[㐀-䶿一-鿿]')
# Characters that exist only in Simplified Chinese; seeing them in zh-Hant means a copy-paste miss.
SIMPLIFIED_ONLY = set('这个机视频设备录请务户网页读选项确应态据储缓阅图画开关闭连账号权隐许总为时间还没载实类')
SIMPLIFIED_ONLY -= set('间')  # 间 is shared with Traditional; kept out on purpose
SPECIFIER = re.compile(r'%(?:\d+\$)?[@dDfFsSuUxXcC]|%l+[du]')

_spec = importlib.util.spec_from_file_location('check_repository', ROOT / 'scripts/check-repository.py')
_repo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_repo)


def strings(language, name):
    text = (RES / f'{language}.lproj' / name).read_text(encoding='utf-8')
    return _repo.openstep('{' + text + '}')


def strip_swift_comments(text):
    return re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)


def problems():
    found = []
    add = found.append
    l10n_text = (ROOT / 'JiangJing/Support/L10n.swift').read_text(encoding='utf-8')
    code_keys = set(re.findall(r'String\(localized: "([^"]+)"', l10n_text))
    info = plistlib.loads((ROOT / 'JiangJing/Info.plist').read_bytes())
    permission_keys = [k for k in info if re.fullmatch(r'NS\w+UsageDescription', k)]

    for language in LANGUAGES:
        if not (RES / f'{language}.lproj').is_dir():
            add(f'missing {language}.lproj')
    if found:
        return found

    for name in ('Localizable.strings', 'InfoPlist.strings'):
        tables = {language: strings(language, name) for language in LANGUAGES}
        reference = set(tables['en'])
        for language, table in tables.items():
            if set(table) != reference:
                add(f'{name}: {language} key mismatch vs en: {sorted(set(table) ^ reference)}')
            for key, value in table.items():
                if not value.strip():
                    add(f'{name}: {language}/{key} is empty')
        for key, value in tables['en'].items():
            if CJK.search(value):
                add(f'{name}: en/{key} contains CJK text')
        for language in ('zh-Hans', 'zh-Hant'):
            for key, value in tables[language].items():
                if not HAN.search(value):
                    add(f'{name}: {language}/{key} has no Chinese text (untranslated?)')
        for key in reference & set(tables['zh-Hant']):
            bad = sorted(SIMPLIFIED_ONLY & set(tables['zh-Hant'][key]))
            if bad:
                add(f'{name}: zh-Hant/{key} has simplified-only characters {bad}')
        for key in reference:
            counts = {language: sorted(SPECIFIER.findall(tables[language].get(key, ''))) for language in LANGUAGES}
            if len({tuple(v) for v in counts.values()}) != 1:
                add(f'{name}: {key} format specifiers differ: {counts}')
        if name == 'Localizable.strings' and set(tables['en']) != code_keys:
            add(f'L10n.swift keys differ from Localizable.strings: {sorted(set(tables["en"]) ^ code_keys)}')
        if name == 'InfoPlist.strings':
            needed = set(permission_keys) | {'CFBundleDisplayName'}
            if not needed <= reference:
                add(f'InfoPlist.strings lacks {sorted(needed - reference)}')

    # The base Info.plist is the development-language (English) fallback.
    for key, value in info.items():
        if isinstance(value, str) and CJK.search(value):
            add(f'Info.plist {key} contains CJK text; base plist must be English')
    if info.get('CFBundleDevelopmentRegion') != 'en':
        add('Info.plist CFBundleDevelopmentRegion must be en')
    if set(info.get('CFBundleLocalizations', [])) != set(LANGUAGES):
        add(f'Info.plist CFBundleLocalizations must be {LANGUAGES}')

    project_yml = (ROOT / 'project.yml').read_text(encoding='utf-8')
    if not re.search(r'^\s*developmentLanguage:\s*en\s*$', project_yml, re.M):
        add('project.yml developmentLanguage must be en')
    regions = re.search(r'knownRegions:\n((?:\s+- .+\n)+)', project_yml)
    if not regions or set(re.findall(r'- (\S+)', regions.group(1))) != set(LANGUAGES):
        add('project.yml knownRegions must be en, zh-Hans, zh-Hant')
    pbx = (ROOT / 'JiangJing.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
    if not re.search(r'developmentRegion = "?en"?;', pbx):
        add('project.pbxproj developmentRegion must be en')
    for language in LANGUAGES:
        for name in ('Localizable.strings', 'InfoPlist.strings'):
            if f'{language}.lproj/{name}' not in pbx:
                add(f'project.pbxproj does not reference {language}.lproj/{name}')

    # Swift sources must not hard-code Chinese; the privacy link must treat all Chinese as Chinese.
    for source in sorted((ROOT / 'JiangJing').rglob('*.swift')):
        if CJK.search(strip_swift_comments(source.read_text(encoding='utf-8'))):
            add(f'{source.relative_to(ROOT)} hard-codes CJK text outside comments')
    privacy = (ROOT / 'JiangJing/Features/PrivacyPolicyView.swift').read_text(encoding='utf-8')
    if 'hasPrefix("zh")' not in privacy or '== "en" ? "en" : "zh"' in privacy:
        add('PrivacyPolicyView must choose the Chinese link for any zh* language and English otherwise')
    return found


def main():
    found = problems()
    for item in found:
        print('FAIL:', item)
    if found:
        return 1
    print('PASS: en/zh-Hans/zh-Hant keys, CJK-free English, project regions and privacy-link rule are consistent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
