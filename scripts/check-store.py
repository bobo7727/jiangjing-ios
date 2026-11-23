#!/usr/bin/env python3
"""Purchase guards. Stdlib only; run from anywhere, no Xcode needed.

Guards the rules in .agents/work/tip-pro/PLAN.md section 2: existing free features stay free, a tip never
touches Pro, product IDs agree everywhere, and the privacy manifest matches what the code uses.
"""
import json
import pathlib
import plistlib
import re
import sys

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / 'JiangJing'
RES = APP / 'Resources'
TIP_ID = 'com.jiangjing.magnifier.tip.small'
PRO_ID = 'com.jiangjing.magnifier.pro'

# Existing free features. None of them may know about purchases.
FREE_FILES = (
    'Camera/CameraController.swift', 'Camera/CameraPreviewView.swift', 'Camera/CaptureState.swift',
    'Camera/LockedFrameState.swift', 'Camera/BackgroundTaskLifetime.swift', 'Camera/PortraitRotation.swift',
    'Features/ControlBar.swift', 'Features/MediaLibraryView.swift', 'Features/ShareSheet.swift',
    'Features/PrivacyPolicyView.swift', 'Media/MediaJournal.swift', 'Media/MediaLibraryModel.swift',
    'Media/PhotoLibrarySaver.swift', 'Support/ZoomScale.swift', 'Support/MagnifierConfig.swift',
    'Support/Haptics.swift',
)
PURCHASE_WORDS = re.compile(r'\b(StoreManager|StoreCatalog|StoreKit|ProStatus|proStatus|isPro|showsProBadge|buyPro|LabelExporter)\b')
# The only files allowed to read Pro state.
PRO_STATE_FILES = {
    'Store/StoreState.swift', 'Store/StoreManager.swift', 'Store/StoreBackend.swift', 'Store/StoreCatalog.swift',
    'Store/LabelExporter.swift', 'Features/SupportView.swift', 'Features/ProPaywallView.swift',
    'Features/LabelEditorView.swift', 'Features/CaptureBanner.swift', 'Features/MagnifierScreen.swift',
    'App/JiangJingApp.swift',
}
UNLOCK_NOTHING = {
    'en': 'unlocks nothing',
    'zh-Hans': '不会解锁任何功能',
    'zh-Hant': '不會解鎖任何功能',
}


def strings(language):
    spec_path = ROOT / 'scripts/check-repository.py'
    import importlib.util
    spec = importlib.util.spec_from_file_location('check_repository', spec_path)
    repo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(repo)
    text = (RES / f'{language}.lproj' / 'Localizable.strings').read_text(encoding='utf-8')
    return repo.openstep('{' + text + '}')


def function_body(text, signature):
    start = text.find(signature)
    if start < 0:
        return None
    brace = text.index('{', start)
    depth = 0
    for index in range(brace, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[brace:index + 1]
    return None


def problems():
    found = []
    add = found.append

    # a) product IDs agree in code, StoreKit test config and the setup doc.
    catalog = (APP / 'Store/StoreCatalog.swift').read_text(encoding='utf-8')
    if set(re.findall(r'"(com\.jiangjing\.magnifier\.[\w.]+)"', catalog)) != {TIP_ID, PRO_ID}:
        add('StoreCatalog.swift product IDs differ from the approved catalog')
    config = json.loads((ROOT / 'StoreKitConfig/JiangJing.storekit').read_text(encoding='utf-8'))
    kinds = {p['productID']: p['type'] for p in config['products']}
    if kinds != {TIP_ID: 'Consumable', PRO_ID: 'NonConsumable'}:
        add(f'StoreKit config products/types wrong: {kinds}')
    prices = {p['productID']: p['displayPrice'] for p in config['products']}
    if prices != {TIP_ID: '0.99', PRO_ID: '2.99'}:
        add(f'StoreKit config prices differ from the approved prices: {prices}')
    if any(p.get('familyShareable') for p in config['products']):
        add('Family Sharing must stay off')
    doc = (ROOT / 'docs/iap-setup.md').read_text(encoding='utf-8')
    for product_id in (TIP_ID, PRO_ID):
        if product_id not in doc:
            add(f'docs/iap-setup.md does not mention {product_id}')

    # b) the StoreKit test config must not ship inside the app sources.
    if list(APP.rglob('*.storekit')):
        add('a .storekit file is inside JiangJing/ and would be bundled into the app')

    # c) existing free features know nothing about purchases.
    for name in FREE_FILES:
        path = APP / name
        if path.exists() and PURCHASE_WORDS.search(path.read_text(encoding='utf-8')):
            add(f'{name}: free feature references purchase state')

    # d) Pro state is only read in the allowed files.
    for path in sorted(APP.rglob('*.swift')):
        relative = path.relative_to(APP).as_posix()
        if relative in PRO_STATE_FILES or relative in FREE_FILES:
            continue
        if PURCHASE_WORDS.search(path.read_text(encoding='utf-8')):
            add(f'{relative}: references purchase state but is not an allowed file')

    # e) a tip never touches Pro.
    manager = (APP / 'Store/StoreManager.swift').read_text(encoding='utf-8')
    body = function_body(manager, 'func buyTip()')
    if body is None:
        add('StoreManager.buyTip() not found')
    elif re.search(r'tracker|proStatus|buyPro|proID', body):
        add('StoreManager.buyTip() touches Pro state')
    state = (APP / 'Store/StoreState.swift').read_text(encoding='utf-8')
    grants = function_body(state, 'static func grantsPro')
    if grants is None or 'StoreCatalog.proID' not in grants:
        add('StoreRules.grantsPro must require the Pro product ID')
    support = (APP / 'Features/SupportView.swift').read_text(encoding='utf-8')
    if re.search(r'buyTip', support) is None:
        add('SupportView must offer the tip')

    # f) tip copy says it unlocks nothing, in every language.
    for language, phrase in UNLOCK_NOTHING.items():
        if phrase not in strings(language).get('support.body', ''):
            add(f'support.body ({language}) must say the tip {phrase!r}')

    # g) UserDefaults use requires the required-reason declaration (CA92.1: app-only preferences).
    uses_defaults = any('UserDefaults' in p.read_text(encoding='utf-8') for p in APP.rglob('*.swift'))
    manifest = plistlib.loads((APP / 'PrivacyInfo.xcprivacy').read_bytes())
    declared = {entry.get('NSPrivacyAccessedAPIType'): entry.get('NSPrivacyAccessedAPITypeReasons')
                for entry in manifest.get('NSPrivacyAccessedAPITypes', [])}
    if uses_defaults and declared.get('NSPrivacyAccessedAPICategoryUserDefaults') != ['CA92.1']:
        add('code uses UserDefaults but PrivacyInfo.xcprivacy lacks NSPrivacyAccessedAPICategoryUserDefaults / CA92.1')
    if not uses_defaults and declared:
        add('PrivacyInfo.xcprivacy declares required-reason APIs the code does not use')
    if manifest.get('NSPrivacyTracking') is not False or manifest.get('NSPrivacyCollectedDataTypes') != []:
        add('privacy manifest must stay: no tracking, no collected data')
    return found


def main():
    found = problems()
    for item in found:
        print('FAIL:', item)
    if found:
        return 1
    print('PASS: product IDs, free-feature isolation, tip/Pro separation, tip copy and privacy manifest agree')
    return 0


if __name__ == '__main__':
    sys.exit(main())
