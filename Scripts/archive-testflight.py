#!/usr/bin/env python3
"""Archive a clean, pinned Build 6 source; validate before optional authorized upload.

Does not expire builds, change tester groups, or submit an App Store release.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--upload', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=root, text=True).strip()
    if git('status', '--porcelain') or git('rev-parse', 'HEAD') != args.source:
        raise SystemExit('Requires the exact clean, reviewed source commit')
    if not args.out.is_absolute() or args.out.exists():
        raise SystemExit('Requires a fresh absolute output directory')
    args.out.mkdir(mode=0o700)
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
        '-derivedDataPath', '/Users/mathiashu/Library/Developer/Hi-Shuzi-QA/build4-b912868-rqK8hMNl/DerivedData',
        *auth, 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES', 'COMPILER_INDEX_STORE_ENABLE=NO'])
    run('export', ['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath',
                  str(args.out / 'export'), '-exportOptionsPlist', str(options), *auth])
    ipa = args.out / 'export/Yishu.ipa'
    run('unpack', ['ditto', '-x', '-k', str(ipa), str(args.out / 'inspect')])
    run('distribution-check', ['python3', 'Scripts/check-distribution-package.py', '--app',
        str(args.out / 'inspect/Payload/Yishu.app'), '--version', '1.4.0', '--build', '6'])
    env = dict(os.environ, API_PRIVATE_KEYS_DIR='/Users/mathiashu/.appstoreconnect/private_keys')
    authentication = ['--api-key', '3W68SK9SZA', '--api-issuer', 'e487f187-a519-4b1f-bd5b-4bd9b3d11b66', '--output-format', 'json']
    run('apple-validation', ['xcrun', 'altool', '--validate-app', str(ipa), *authentication], env)
    sha = hashlib.sha256(ipa.read_bytes()).hexdigest()
    record = {'source': args.source, 'version': '1.4.0', 'build': '6', 'ipa': str(ipa),
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
