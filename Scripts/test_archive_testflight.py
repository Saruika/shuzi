#!/usr/bin/env python3
"""Pure local contract tests: no git, Xcode, credential access or upload executes."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name('archive-testflight.py')
SPEC = importlib.util.spec_from_file_location('archive_testflight', SCRIPT)
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)

SOURCE = 'a' * 40
VERSION = '2.6.3'
BUILD = '47.2'


def settings_payload(**overrides):
    settings = {
        'CONFIGURATION': 'Release',
        'PRODUCT_BUNDLE_IDENTIFIER': 'cn.com.shuzijun.yishu',
        'MARKETING_VERSION': VERSION,
        'CURRENT_PROJECT_VERSION': BUILD,
    }
    settings.update(overrides)
    return [{'target': 'Yishu', 'buildSettings': settings}]


class ArchiveTestFlightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='test-archive-testflight-')
        self.addCleanup(self.temporary.cleanup)
        self.out = Path(self.temporary.name) / 'release'
        self.commands = []
        self.git_commands = []
        self.settings = json.dumps(settings_payload())
        self.fail_stage = None
        self.dirty = False
        self.change_after_settings = False
        self.head = SOURCE
        self.mutate_during_validation = False
        self.timeout_settings = False
        self.ipa_bytes = b'local-test-fixture-not-an-ipa'

    def arguments(self, upload=False):
        arguments = ['--source', SOURCE, '--out', str(self.out), '--version', VERSION, '--build', BUILD]
        return arguments + (['--upload'] if upload else [])

    def fake_git(self, command, **kwargs):
        self.git_commands.append(command)
        if command == ['git', 'status', '--porcelain']:
            return ' M tracked-file' if self.dirty or (self.change_after_settings and self.commands) else ''
        if command == ['git', 'rev-parse', 'HEAD']:
            return self.head
        self.fail(f'Unexpected git command: {command}')

    def fake_run(self, command, **kwargs):
        self.commands.append(command)
        if '-showBuildSettings' in command:
            if self.timeout_settings:
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])
            stage = 'build-settings'
        elif command[:2] == ['xcodebuild', 'archive']:
            stage = 'archive'
        elif '-exportArchive' in command:
            stage = 'export'
        elif command[0] == 'ditto':
            stage = 'unpack'
        elif command[:2] == ['python3', 'Scripts/check-distribution-package.py']:
            stage = 'distribution-check'
        elif '--validate-app' in command:
            stage = 'apple-validation'
        elif '--upload-app' in command:
            stage = 'apple-upload'
        else:
            self.fail(f'Unexpected subprocess: {command}')
        if stage == self.fail_stage:
            return SimpleNamespace(returncode=1, stdout=self.settings)
        if stage == 'export':
            destination = self.out / 'export'
            destination.mkdir()
            (destination / 'Yishu.ipa').write_bytes(self.ipa_bytes)
        if stage == 'apple-validation' and self.mutate_during_validation:
            (self.out / 'export/Yishu.ipa').write_bytes(b'changed-during-validation')
        return SimpleNamespace(returncode=0, stdout=self.settings if stage == 'build-settings' else None)

    @contextlib.contextmanager
    def local_processes(self):
        with patch.object(archive.subprocess, 'check_output', side_effect=self.fake_git), \
             patch.object(archive.subprocess, 'run', side_effect=self.fake_run), \
             patch.object(archive.os, 'umask'), contextlib.redirect_stdout(io.StringIO()):
            yield

    def test_version_and_build_are_required_before_any_subprocess(self):
        arguments = self.arguments()
        for option in ['--version', '--build']:
            missing = arguments.copy()
            index = missing.index(option)
            del missing[index:index + 2]
            with self.subTest(option=option), self.local_processes(), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    archive.main(missing)
                self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.git_commands, [])
        self.assertFalse(self.out.exists())

    def test_explicit_values_preserved_and_blank_or_padded_values_rejected(self):
        parsed = archive.parse_args(self.arguments())
        self.assertEqual((parsed.version, parsed.build), (VERSION, BUILD))
        self.assertFalse(parsed.upload)
        for option in ['--version', '--build']:
            for invalid in ['', ' ', ' 47', '47 ']:
                arguments = self.arguments()
                arguments[arguments.index(option) + 1] = invalid
                with self.subTest(option=option, value=invalid), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        archive.parse_args(arguments)

    def test_settings_require_exact_app_target_and_all_release_identifiers(self):
        self.assertEqual(archive.validate_release_settings(settings_payload(), VERSION, BUILD)['CONFIGURATION'], 'Release')
        invalid_payloads = [None, {}, [], [{'target': 'YishuTests', 'buildSettings': settings_payload()[0]['buildSettings']}],
                            settings_payload() * 2, [{'target': 'Yishu', 'buildSettings': None}]]
        for key in ['CONFIGURATION', 'PRODUCT_BUNDLE_IDENTIFIER', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
            invalid_payloads.append(settings_payload(**{key: 'different'}))
            payload = settings_payload()
            del payload[0]['buildSettings'][key]
            invalid_payloads.append(payload)
        for payload in invalid_payloads:
            with self.subTest(payload=payload), self.assertRaises(SystemExit):
                archive.validate_release_settings(payload, VERSION, BUILD)

    def test_dirty_or_wrong_source_refuses_even_settings_inspection(self):
        for dirty, head in [(True, SOURCE), (False, 'b' * 40)]:
            self.dirty, self.head = dirty, head
            with self.subTest(dirty=dirty), self.local_processes():
                with self.assertRaisesRegex(SystemExit, 'exact clean'):
                    archive.main(self.arguments())
            self.assertEqual(self.commands, [])
            self.assertFalse(self.out.exists())

    def test_output_must_be_fresh_and_absolute(self):
        for out in [Path('relative-release'), Path(self.temporary.name)]:
            self.out = out
            with self.subTest(out=out), self.local_processes():
                with self.assertRaisesRegex(SystemExit, 'fresh absolute'):
                    archive.main(self.arguments())
            self.assertEqual(self.commands, [])

    def test_settings_mismatch_stops_before_archive_export_or_provisioning(self):
        self.settings = json.dumps(settings_payload(CURRENT_PROJECT_VERSION='999'))
        with self.local_processes(), self.assertRaisesRegex(SystemExit, 'CURRENT_PROJECT_VERSION'):
            archive.main(self.arguments(upload=True))
        self.assertEqual(len(self.commands), 1)
        self.assertIn('-showBuildSettings', self.commands[0])
        self.assertNotIn('-allowProvisioningUpdates', self.commands[0])
        self.assertNotIn('-authenticationKeyPath', self.commands[0])
        self.assertFalse((self.out / 'ExportOptions.plist').exists())

    def test_malformed_settings_json_stops_before_archive(self):
        self.settings = 'not JSON'
        with self.local_processes(), self.assertRaisesRegex(SystemExit, 'Invalid Release build settings JSON'):
            archive.main(self.arguments())
        self.assertEqual(len(self.commands), 1)

    def test_settings_failure_or_timeout_is_not_retried(self):
        for failure in ['exit', 'timeout']:
            self.out = Path(self.temporary.name) / failure
            self.commands = []
            self.fail_stage = 'build-settings' if failure == 'exit' else None
            self.timeout_settings = failure == 'timeout'
            with self.subTest(failure=failure), self.local_processes():
                with self.assertRaisesRegex(SystemExit, 'build-settings; no automatic retry'):
                    archive.main(self.arguments())
            self.assertEqual(len(self.commands), 1)

    def test_source_change_during_settings_inspection_refuses_archive(self):
        self.change_after_settings = True
        with self.local_processes(), self.assertRaisesRegex(SystemExit, 'exact clean'):
            archive.main(self.arguments())
        self.assertEqual(len(self.commands), 1)
        self.assertFalse((self.out / 'ExportOptions.plist').exists())

    def test_requested_version_build_and_fresh_derived_data_reach_checks_and_record(self):
        with self.local_processes():
            archive.main(self.arguments())
        self.assertEqual(len(self.commands), 6)
        for command in self.commands[:2]:
            self.assertEqual(command[command.index('-derivedDataPath') + 1], str(self.out / 'DerivedData'))
            self.assertEqual(command[command.index('-configuration') + 1], 'Release')
        package_check = self.commands[4]
        self.assertEqual(package_check[package_check.index('--version') + 1], VERSION)
        self.assertEqual(package_check[package_check.index('--build') + 1], BUILD)
        record = json.loads((self.out / 'artifact.json').read_text())
        self.assertEqual((record['source'], record['version'], record['build']), (SOURCE, VERSION, BUILD))
        self.assertEqual(record['sha256'], hashlib.sha256(self.ipa_bytes).hexdigest())
        self.assertTrue(record['validated'])
        self.assertFalse(record['uploaded'])
        self.assertFalse((self.out / 'uploaded.json').exists())

    def test_each_failed_stage_stops_without_retry_or_later_upload(self):
        for stage in ['archive', 'export', 'unpack', 'distribution-check', 'apple-validation', 'apple-upload']:
            self.out = Path(self.temporary.name) / stage
            self.commands = []
            self.fail_stage = stage
            with self.subTest(stage=stage), self.local_processes():
                with self.assertRaisesRegex(SystemExit, f'Stopped at {stage}; no automatic retry'):
                    archive.main(self.arguments(upload=True))
            self.assertEqual(len(self.commands), ['archive', 'export', 'unpack', 'distribution-check', 'apple-validation', 'apple-upload'].index(stage) + 2)
            self.assertFalse((self.out / 'uploaded.json').exists())

    def test_changed_ipa_during_validation_refuses_a_validated_record_and_upload(self):
        self.mutate_during_validation = True
        with self.local_processes(), self.assertRaisesRegex(SystemExit, 'changed during validation'):
            archive.main(self.arguments(upload=True))
        self.assertFalse(any('--upload-app' in command for command in self.commands))
        self.assertFalse((self.out / 'artifact.json').exists())

    def test_changed_ipa_after_record_refuses_upload(self):
        original_dump = json.dump
        def replace_after_record(record, file):
            original_dump(record, file)
            if Path(file.name).name == 'artifact.json':
                (self.out / 'export/Yishu.ipa').write_bytes(b'changed-after-record')
        with self.local_processes(), patch.object(archive.json, 'dump', side_effect=replace_after_record):
            with self.assertRaisesRegex(SystemExit, 'Validated artifact changed'):
                archive.main(self.arguments(upload=True))
        self.assertFalse(any('--upload-app' in command for command in self.commands))
        self.assertFalse((self.out / 'uploaded.json').exists())

    def test_explicit_upload_uses_the_identical_validated_ipa_path_and_hash(self):
        with self.local_processes():
            archive.main(self.arguments(upload=True))
        validation = next(command for command in self.commands if '--validate-app' in command)
        upload = next(command for command in self.commands if '--upload-app' in command)
        self.assertEqual(validation[validation.index('--validate-app') + 1], upload[upload.index('-f') + 1])
        validated = json.loads((self.out / 'artifact.json').read_text())
        uploaded = json.loads((self.out / 'uploaded.json').read_text())
        self.assertFalse(validated['uploaded'])
        self.assertTrue(uploaded.pop('uploaded'))
        validated.pop('uploaded')
        self.assertEqual(uploaded, validated)


if __name__ == '__main__':
    unittest.main()
