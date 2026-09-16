#!/usr/bin/env python3
"""Archive an explicitly versioned, clean source; validate before optional authorized upload.

Does not expire builds, change tester groups, or submit an App Store release.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--upload', action='store_true')
    args = parser.parse_args(argv)
    for name in ('version', 'build'):
        value = getattr(args, name)
        if not value or value != value.strip():
            parser.error('--' + name + ' must be a non-empty value without surrounding whitespace')
    return args


def validate_release_settings(data, version, build):
    if not isinstance(data, list):
        raise SystemExit('Release build settings must contain a target list')
    targets = [item for item in data if isinstance(item, dict) and item.get('target') == 'Yishu']
    if len(targets) != 1 or not isinstance(targets[0].get('buildSettings'), dict):
        raise SystemExit('Requires exactly one Yishu target with Release build settings')
    settings = targets[0]['buildSettings']
    expected = {
        'CONFIGURATION': 'Release',
        'PRODUCT_BUNDLE_IDENTIFIER': 'cn.com.shuzijun.yishu',
        'MARKETING_VERSION': version,
        'CURRENT_PROJECT_VERSION': build,
    }
    mismatches = [key for key, value in expected.items() if settings.get(key) != value]
    if mismatches:
        raise SystemExit('Release build settings do not match requested artifact: ' + ', '.join(mismatches))
    return expected


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=root, text=True).strip()
    def require_source():
        if git('status', '--porcelain') or git('rev-parse', 'HEAD') != args.source:
            raise SystemExit('Requires the exact clean, reviewed source commit')
    require_source()
    if not args.out.is_absolute() or args.out.exists():
        raise SystemExit('Requires a fresh absolute output directory')
    args.out.mkdir(mode=0o700)
    derived_data = args.out / 'DerivedData'

    # Inspect the same Release target before any archive/export/provisioning work.
    # Keep stderr separate so Xcode diagnostics cannot masquerade as settings JSON.
    print('build-settings: started', flush=True)
    with (args.out / 'build-settings.log').open('x') as log:
        try:
            settings_result = subprocess.run(
                ['xcodebuild', '-showBuildSettings', '-json', '-project', 'Yishu.xcodeproj',
                 '-scheme', 'Yishu', '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                 '-derivedDataPath', str(derived_data)],
                cwd=root, stdout=subprocess.PIPE, stderr=log, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            raise SystemExit('Stopped at build-settings; no automatic retry') from None
    print('build-settings: exit=' + str(settings_result.returncode), flush=True)
    if settings_result.returncode:
        raise SystemExit('Stopped at build-settings; no automatic retry')
    with (args.out / 'build-settings.json').open('x') as file:
        file.write(settings_result.stdout)
    try:
        settings = json.loads(settings_result.stdout)
    except (json.JSONDecodeError, TypeError):
        raise SystemExit('Invalid Release build settings JSON; refusing archive') from None
    validate_release_settings(settings, args.version, args.build)
    require_source()

    def run(name, command, env=None):
        print(name + ': started', flush=True)
        with (args.out / (name + '.log')).open('x') as log:
            result = subprocess.run(command, cwd=root, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=2400)
        print(name + ': exit=' + str(result.returncode), flush=True)
        if result.returncode:
            raise SystemExit('Stopped at ' + name + '; no automatic retry')
    options = args.out / 'ExportOptions.plist'
    with options.open('xb') as file:
        plistlib.dump({'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'automatic',
                      'manageAppVersionAndBuildNumber': False, 'stripSwiftSymbols': True,
                      'teamID': '6F34K54BYJ', 'uploadSymbols': True}, file)
    auth = ['-allowProvisioningUpdates', '-authenticationKeyPath',
            '/Users/mathiashu/.appstoreconnect/private_keys/AuthKey_3W68SK9SZA.p8',
            '-authenticationKeyID', '3W68SK9SZA', '-authenticationKeyIssuerID',
            'e487f187-a519-4b1f-bd5b-4bd9b3d11b66']
    archive = args.out / 'Yishu.xcarchive'
    run('archive', ['xcodebuild', 'archive', '-project', 'Yishu.xcodeproj', '-scheme', 'Yishu',
        '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', str(archive),
        '-derivedDataPath', str(derived_data),
        *auth, 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES', 'COMPILER_INDEX_STORE_ENABLE=NO'])
    run('export', ['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath',
                  str(args.out / 'export'), '-exportOptionsPlist', str(options), *auth])
    ipa = args.out / 'export/Yishu.ipa'
    run('unpack', ['ditto', '-x', '-k', str(ipa), str(args.out / 'inspect')])
    run('distribution-check', ['python3', 'Scripts/check-distribution-package.py', '--app',
        str(args.out / 'inspect/Payload/Yishu.app'), '--version', args.version, '--build', args.build])
    env = dict(os.environ, API_PRIVATE_KEYS_DIR='/Users/mathiashu/.appstoreconnect/private_keys')
    authentication = ['--api-key', '3W68SK9SZA', '--api-issuer', 'e487f187-a519-4b1f-bd5b-4bd9b3d11b66', '--output-format', 'json']
    sha = hashlib.sha256(ipa.read_bytes()).hexdigest()
    run('apple-validation', ['xcrun', 'altool', '--validate-app', str(ipa), *authentication], env)
    if hashlib.sha256(ipa.read_bytes()).hexdigest() != sha:
        raise SystemExit('Artifact changed during validation; refusing upload')
    record = {'source': args.source, 'version': args.version, 'build': args.build, 'ipa': str(ipa),
              'sha256': sha, 'bytes': ipa.stat().st_size, 'validated': True, 'uploaded': False}
    with (args.out / 'artifact.json').open('x') as file:
        json.dump(record, file)
    if args.upload:
        if hashlib.sha256(ipa.read_bytes()).hexdigest() != sha:
            raise SystemExit('Validated artifact changed; refusing upload')
        run('apple-upload', ['xcrun', 'altool', '--upload-app', '-f', str(ipa), *authentication], env)
        record['uploaded'] = True
        with (args.out / 'uploaded.json').open('x') as file:
            json.dump(record, file)
    print(json.dumps(record), flush=True)


if __name__ == '__main__':
    main()
