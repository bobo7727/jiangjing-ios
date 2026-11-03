#!/usr/bin/env python3
"""Release only: require public policies before signing. Does not publish anything."""
import os
import plistlib
import urllib.parse
import urllib.request
from pathlib import Path

values = {}
for language in ('en', 'zh'):
    key = f'PRIVACY_POLICY_URL_{language.upper()}'
    url = os.environ.get(key, '')
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.hostname.endswith('example.com'):
        raise SystemExit(f'{key}: provide the real public HTTPS privacy policy URL')
    with urllib.request.urlopen(url, timeout=30) as response:
        if response.status != 200 or urllib.parse.urlparse(response.url).scheme != 'https':
            raise SystemExit(f'{key}: expected a publicly accessible HTTPS page')
        body = response.read(2_000_000).decode('utf-8')
        # A transport check cannot certify policy content or legal completeness.
        if 'JiangJing' not in body or ('Privacy' not in body and '隐私' not in body):
            raise SystemExit(f'{key}: the returned page does not identify the JiangJing privacy policy')
    values[f'JiangJingPrivacyPolicyURL_{language}'] = url
path = Path('JiangJing/Info.plist')
with path.open('rb') as stream:
    info = plistlib.load(stream)
info.update(values)
with path.open('wb') as stream:
    plistlib.dump(info, stream, sort_keys=False)
print('Public policy URLs verified and included in this release build.')
