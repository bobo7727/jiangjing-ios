#!/usr/bin/env python3
"""Check the built app, not just project input declarations."""
import json
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.jiangjing.magnifier'
assert info['MinimumOSVersion'] == '16.0'
assert info['ITSAppUsesNonExemptEncryption'] is False
for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSPhotoLibraryAddUsageDescription'):
    assert info[key].strip(), key
for language in ('en', 'zh-Hans'):
    for resource in ('Localizable.strings', 'InfoPlist.strings'):
        assert (app / f'{language}.lproj' / resource).is_file(), (language, resource)
assert (app / 'Assets.car').is_file()
assert info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') == 'AppIcon'
with (app / 'PrivacyInfo.xcprivacy').open('rb') as stream:
    privacy = plistlib.load(stream)
assert privacy['NSPrivacyTracking'] is False
print(json.dumps({'bundle': info['CFBundleIdentifier'], 'minimumOS': info['MinimumOSVersion'],
                  'resources': 'localizations, icons, privacy manifest present'}, indent=2))
