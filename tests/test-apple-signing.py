#!/usr/bin/env python3
"""Regression checks for nested signing, credential isolation and unknown submissions."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('apple_signing', Path(__file__).resolve().parents[1] / 'scripts/apple-signing.py')
apple = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apple)
TEAM = 'ABCDEFGHIJ'
NAME = f'Developer ID Application: Fixture Inc. ({TEAM})'
FINGERPRINT = 'A' * 40
SUBMISSION = '56d25a54-87b2-45b1-a994-c58256b59e58'
ENVIRONMENT = {'APPLE_CERTIFICATE': base64.b64encode(b'fixture').decode(), 'APPLE_CERTIFICATE_PASSWORD': 'fixture-p12',
               'APPLE_SIGNING_IDENTITY': NAME, 'APPLE_TEAM_ID': TEAM, 'APPLE_ID': 'fixture@example.invalid',
               'APPLE_PASSWORD': 'fixture-app-password'}


class AppleSigningTests(unittest.TestCase):
    def test_rejects_wrong_team_and_missing_notary_credentials(self):
        for environment in (ENVIRONMENT | {'APPLE_TEAM_ID': 'ZZZZZZZZZZ'}, ENVIRONMENT | {'APPLE_PASSWORD': ''},
                            ENVIRONMENT | {'APPLE_CERTIFICATE': 'not base64'}):
            with self.subTest(environment=environment.keys()), self.assertRaises(SystemExit):
                apple.validate_environment(True, environment)

    def test_same_named_certificate_is_selected_from_imported_keychain(self):
        output = f'  1) {FINGERPRINT} "{NAME}"\n  1 valid identities found\n'
        with patch.object(apple, 'run', return_value=output):
            self.assertEqual(apple.find_identity(Path('/fixture.keychain'), NAME), FINGERPRINT)
        with patch.object(apple, 'run', return_value=output + output), self.assertRaises(SystemExit):
            apple.find_identity(Path('/fixture.keychain'), NAME)

    def test_keychain_restored_and_credentials_removed_on_child_failure(self):
        calls = []

        def run(arguments):
            arguments = list(map(str, arguments))
            calls.append(arguments)
            if arguments[:4] == ['security', 'list-keychains', '-d', 'user'] and len(arguments) == 4:
                return '"/fixture/login.keychain-db"\n'
            if arguments[:2] == ['security', 'create-keychain']:
                Path(arguments[-1]).touch()
            if arguments[:2] == ['security', 'find-identity']:
                return f'  1) {FINGERPRINT} "{NAME}"\n'
            return ''

        with patch.dict(os.environ, ENVIRONMENT, clear=True), patch.object(apple, 'run', side_effect=run):
            with self.assertRaisesRegex(RuntimeError, 'child failure'):
                with apple.signing_environment(True) as environment:
                    self.assertEqual(environment['SHOU_SIGNING_IDENTITY'], FINGERPRINT)
                    self.assertEqual(environment['SHOU_SIGNING_TIMESTAMP'], 'required')
                    for key in (*apple.SIGNING_SECRETS, *apple.NOTARY_SECRETS):
                        if key != 'APPLE_TEAM_ID':
                            self.assertNotIn(key, environment)
                    raise RuntimeError('child failure')
        self.assertEqual(calls[-2], ['security', 'list-keychains', '-d', 'user', '-s', '/fixture/login.keychain-db'])
        self.assertEqual(calls[-1][:2], ['security', 'delete-keychain'])

    def test_nested_code_is_signed_before_containers_without_following_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Shou.app'
            framework = app / 'Contents/Frameworks/Sparkle.framework'
            xpc = framework / 'Versions/B/XPCServices/Downloader.xpc'
            binaries = [app / 'Contents/MacOS/Shou', app / 'Contents/Helpers/shou',
                        xpc / 'Contents/MacOS/Downloader', framework / 'Versions/B/Sparkle']
            for binary in binaries:
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.limecloud.shou'}))
            (framework / 'Versions/Current').symlink_to('B', target_is_directory=True)
            (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
            calls = []
            environment = {'SHOU_SIGNING_IDENTITY': FINGERPRINT, 'APPLE_TEAM_ID': TEAM, 'SHOU_SIGNING_TIMESTAMP': 'required'}
            with patch.dict(os.environ, environment, clear=True), patch.object(apple, 'run', side_effect=lambda args: calls.append(args) or ''), patch.object(apple, 'verify_app'):
                apple.sign_app(app)
            paths = [call[-1] for call in calls]
            self.assertEqual(len(paths), len(set(paths)))
            self.assertLess(paths.index(binaries[2]), paths.index(xpc))
            self.assertLess(paths.index(xpc), paths.index(framework))
            self.assertEqual(paths[-1], app)
            cli_call = next(call for call in calls if call[-1] == binaries[1])
            self.assertIn('dev.limecloud.shou.cli', cli_call)
            self.assertTrue(all('--deep' not in call and '--timestamp' in call for call in calls))
            self.assertEqual(plistlib.loads(info.read_bytes())['ShouSigningMode'], 'developer-id')

    def test_unknown_notarization_retains_submission_and_prevents_resubmission(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'evidence'
            environment = {'SHOU_SIGNING_KEYCHAIN': '/fixture.keychain', 'SHOU_NOTARY_PROFILE': 'fixture'}
            with patch.dict(os.environ, environment, clear=True), patch.object(apple, 'run', side_effect=[json.dumps({'id': SUBMISSION}), SystemExit('timeout')]) as run:
                with self.assertRaisesRegex(SystemExit, 'timeout'):
                    apple.notarize(Path('/fixture.zip'), evidence)
                self.assertEqual(json.loads((evidence / 'submission.json').read_text())['id'], SUBMISSION)
                with self.assertRaisesRegex(SystemExit, 'already exists'):
                    apple.notarize(Path('/fixture.zip'), evidence)
                self.assertEqual(run.call_count, 2)

    def test_failed_or_mismatched_notarization_never_staples(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = {'SHOU_SIGNING_KEYCHAIN': '/fixture.keychain', 'SHOU_NOTARY_PROFILE': 'fixture'}
            for index, result in enumerate(({'id': SUBMISSION, 'status': 'Invalid'}, {'id': 'other', 'status': 'Accepted'})):
                def run(arguments):
                    if arguments[:3] == ['xcrun', 'notarytool', 'submit']:
                        return json.dumps({'id': SUBMISSION})
                    if arguments[:3] == ['xcrun', 'notarytool', 'wait']:
                        return json.dumps(result)
                    return ''
                with patch.dict(os.environ, environment, clear=True), patch.object(apple, 'run', side_effect=run) as command, patch.object(apple, 'verify_app'):
                    with self.assertRaisesRegex(SystemExit, 'not accepted'):
                        apple.notarize_app(Path('/fixture.app'), Path(directory) / str(index))
                    self.assertFalse(any(call.args[0][:2] == ['xcrun', 'stapler'] for call in command.call_args_list))

    def test_errors_do_not_expose_secret_arguments_or_values(self):
        result = subprocess.CompletedProcess(['fixture'], 1, 'failed ' + ENVIRONMENT['APPLE_PASSWORD'])
        with patch.dict(os.environ, ENVIRONMENT, clear=True), patch.object(apple.subprocess, 'run', return_value=result):
            with self.assertRaises(SystemExit) as error:
                apple.run(['fixture', ENVIRONMENT['APPLE_CERTIFICATE_PASSWORD']])
            self.assertNotIn(ENVIRONMENT['APPLE_PASSWORD'], str(error.exception))
            self.assertNotIn(ENVIRONMENT['APPLE_CERTIFICATE_PASSWORD'], str(error.exception))


if __name__ == '__main__':
    unittest.main()
