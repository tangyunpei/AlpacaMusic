#!/usr/bin/env python3
"""Check the shipping translations and optionally Swift's extracted string keys.

Usage: python3 scripts/check-localizations.py [--extracted-dir DIR]
Generate compiler keys with swift build -Xswiftc -emit-localized-strings.
With SwiftBuild, use --extracted-dir .build.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PAIR = re.compile(r'\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(lld|llu|ld|lu|d|u|lf|f|g|@)')
HAN = re.compile(r'[\u3400-\u9fff]')

def strings(path):
    result = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('//'):
            continue
        match = PAIR.fullmatch(line)
        if not match:
            raise ValueError(f'{path}:{number}: invalid .strings entry')
        key, value = (json.loads(part) for part in match.groups())
        if key in result:
            raise ValueError(f'{path}:{number}: duplicate key {key!r}')
        if not value.strip():
            raise ValueError(f'{path}:{number}: empty translation {key!r}')
        result[key] = value
    return result

def formats(text):
    # %% is a literal percent, never an argument.
    return [(int(m.group(1)) if m.group(1) else index, m.group(2))
            for index, m in enumerate(FORMAT.finditer(text.replace('%%', '')), 1)]

def check(extracted=None):
    base = ROOT / 'Sources/AlpacaMusic/Localization'
    en = strings(base / 'en.lproj/Localizable.strings')
    zh = strings(base / 'zh-Hans.lproj/Localizable.strings')
    if en.keys() != zh.keys():
        raise ValueError(f'Language keys differ: {sorted(en.keys() ^ zh.keys())}')
    for key in en:
        for language, values in [('en', en), ('zh-Hans', zh)]:
            if Counter(formats(key)) != Counter(formats(values[key])):
                raise ValueError(f'{language}: format arguments differ for {key!r}')
            if language == 'en' and HAN.search(values[key]):
                raise ValueError(f'Untranslated English value for {key!r}')
    for language in ('en', 'zh-Hans'):
        prompts = strings(ROOT / f'Resources/Localization/{language}.lproj/InfoPlist.strings')
        if not {'NSAppleMusicUsageDescription', 'NSLocalNetworkUsageDescription'} <= prompts.keys():
            raise ValueError(f'{language}: system permission prompts are missing')
    plural_path = base / 'en.lproj/Localizable.stringsdict'
    if plural_path.exists():
        plural = plistlib.loads(plural_path.read_bytes())
        for key, entry in plural.items():
            if key not in en:
                raise ValueError(f'Unknown plural key {key!r}')
            for name, rule in entry.items():
                if name == 'NSStringLocalizedFormatKey':
                    continue
                if not {'one', 'other', 'NSStringFormatSpecTypeKey', 'NSStringFormatValueTypeKey'} <= rule.keys():
                    raise ValueError(f'Incomplete plural rule for {key!r}')
    if extracted:
        files = list(Path(extracted).rglob('*.stringsdata'))
        if not files:
            raise ValueError('No compiler .stringsdata found; cannot confirm source coverage')
        missing = {}
        for path in files:
            data = json.loads(path.read_text())
            # Skip tests, standalone QA fixture text, and system-owned labels.
            if '/Sources/AlpacaMusic/' not in data.get('source', ''):
                continue
            for entry in data.get('tables', {}).get('Localizable', []):
                key = entry['key']
                if HAN.search(key) and key not in en:
                    missing[key] = data['source']
        if missing:
            raise ValueError('Missing compiler-extracted translations:\n' + '\n'.join(f'{k}: {v}' for k,v in sorted(missing.items())))
    print(f'Localization checks passed: {len(en)} keys, English and Simplified Chinese, typed placeholders and permission prompts.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extracted-dir')
    args = parser.parse_args()
    try:
        check(args.extracted_dir)
    except (ValueError, OSError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
