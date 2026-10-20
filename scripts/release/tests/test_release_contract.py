"""Prepared for independent QA; this implementation session does not run tests.

Run: python3 -B -m unittest discover -s scripts/release/tests -v
No Xcode builds, Keychain changes, devices, network, or user data.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import ssl
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

sys.dont_write_bytecode = True
MODULES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MODULES))
from common import INPUTS, ProcessTracker, ReleaseError, run, tree_hash
from manifest import validate_manifest
from pipeline import export_options, fresh_output, identity_exists, validate_build_receipt
from source import check_commit, privacy, input_manifest, manifest_hash, validate_input_manifest
from validate import check_bundle, check_entitlements, check_profile, safe_zip


class ReleaseContractTests(unittest.TestCase):
    def cli(self, *args):
        return subprocess.run([sys.executable, '-B', str(MODULES / 'main.py'), *args],
                              capture_output=True, text=True, timeout=20,
                              env={key: value for key, value in os.environ.items() if not key.startswith('CUBIC_')})

    def test_cli_refuses_missing_parameters_before_any_build(self):
        result = self.cli('preflight')
        self.assertEqual(result.returncode, 2)
        self.assertIn('缺必要参数', result.stderr)

    def test_cli_rejects_cross_platform_channel(self):
        result = self.cli('export-options', '--platform', 'macos', '--channel', 'ad-hoc',
                          '--team-id', 'ABCDE12345', '--identity', 'a' * 40)
        self.assertEqual(result.returncode, 2)
        self.assertIn('channel/platform', result.stderr)

    def test_export_preserves_shared_version_and_never_uploads(self):
        for channel in ('testflight', 'app-store', 'ad-hoc'):
            value = export_options({'platform': 'ios', 'channel': channel, 'team_id': 'ABCDE12345',
                                    'ios_bundle_id': 'local.liwei.Cubic'}, 'a' * 40, 'PROFILE')
            self.assertEqual(value['destination'], 'export')
            self.assertFalse(value['manageAppVersionAndBuildNumber'])
            self.assertNotIn('iCloudContainerEnvironment', value)

    def test_dirty_source_cannot_be_presented_as_clean_commit(self):
        def git(argv, **kwargs):
            if argv[1] == 'rev-parse':
                return 'a' * 40 + '\n'
            if argv[1] == 'status':
                return '?? CubicApp/forgotten.swift\n'
            self.fail('dirty source must stop before export')
        with patch('source.run', side_effect=git), self.assertRaisesRegex(ReleaseError, '未提交'):
            check_commit('a' * 40)

    def test_new_attempt_does_not_overwrite_previous_artifact(self):
        request = {'version': '1.2.3', 'build_number': '42', 'platform': 'macos', 'channel': 'developer-id'}
        with tempfile.TemporaryDirectory(prefix='Release QA with spaces ') as root:
            previous = fresh_output(root, request, 'package')
            (previous / 'passed.zip').write_bytes(b'previous accepted bytes')
            current = fresh_output(root, request, 'package')
            self.assertNotEqual(previous, current)
            self.assertEqual((previous / 'passed.zip').read_bytes(), b'previous accepted bytes')

    def profile_fixture(self, devices=True):
        value = {'TeamIdentifier': ['ABCDE12345'], 'ApplicationIdentifierPrefix': ['ABCDE12345'], 'DeveloperCertificates': [b'certificate'],
                 'ExpirationDate': dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30),
                 'Entitlements': {'application-identifier': 'ABCDE12345.local.liwei.Cubic',
                                  'com.apple.developer.team-identifier': 'ABCDE12345', 'get-task-allow': False}}
        if devices:
            value['ProvisionedDevices'] = ['TEST-DEVICE-IDENTIFIER-00001']
        return value

    def test_adhoc_blocks_unregistered_device_and_short_window(self):
        value = self.profile_fixture()
        with self.assertRaisesRegex(ReleaseError, '未覆盖'):
            check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'ad-hoc', ['OTHER-DEVICE'], 7)
        with self.assertRaisesRegex(ReleaseError, '测试窗口'):
            check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'ad-hoc', value['ProvisionedDevices'], 31)

    def test_profile_cannot_use_negative_window_to_accept_expired_assets(self):
        value = self.profile_fixture()
        value['ExpirationDate'] = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)
        with self.assertRaisesRegex(ReleaseError, '测试窗口'):
            check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'ad-hoc', value['ProvisionedDevices'], -7)
        with self.assertRaisesRegex(ReleaseError, '至少'):
            check_profile(self.profile_fixture(), 'ABCDE12345', 'local.liwei.Cubic', 'ad-hoc',
                          value['ProvisionedDevices'], 0)

    def test_profile_summary_does_not_disclose_device_identifiers(self):
        value = self.profile_fixture()
        result = check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'ad-hoc', value['ProvisionedDevices'], 7)
        self.assertNotIn(value['ProvisionedDevices'][0], json.dumps(result))
        self.assertIn('expiration_utc', result)

    def test_archive_development_signature_is_allowed_but_export_is_not(self):
        value = self.profile_fixture()
        value['Entitlements']['get-task-allow'] = True
        check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'archive-development')
        with self.assertRaises(ReleaseError):
            check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'ad-hoc', value['ProvisionedDevices'], 7)

    def test_asc_profile_cannot_contain_registered_device_list(self):
        with self.assertRaises(ReleaseError):
            check_profile(self.profile_fixture(), 'ABCDE12345', 'local.liwei.Cubic', 'testflight')

    def test_distribution_certificate_must_be_in_profile(self):
        with self.assertRaisesRegex(ReleaseError, 'certificate'):
            check_profile(self.profile_fixture(False), 'ABCDE12345', 'local.liwei.Cubic', 'testflight', identity='0' * 40)

    def test_final_entitlements_block_debugger_and_cloudkit(self):
        for ent in ({'get-task-allow': True}, {'com.apple.security.get-task-allow': True},
                    {'com.apple.developer.icloud-container-identifiers': ['iCloud.invalid']}):
            with self.subTest(ent=ent), self.assertRaises(ReleaseError):
                check_entitlements(ent, 'ios', 'ABCDE12345', 'local.liwei.Cubic')

    def test_profile_exact_app_id_and_legacy_prefix(self):
        value = self.profile_fixture(False)
        value['Entitlements']['application-identifier'] = 'ABCDE12345.other.local.liwei.Cubic'
        with self.assertRaisesRegex(ReleaseError, 'exact Bundle ID'):
            check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'testflight')
        with self.assertRaisesRegex(ReleaseError, 'application identifier'):
            check_entitlements(value['Entitlements'], 'ios', 'ABCDE12345', 'local.liwei.Cubic')
        value['ApplicationIdentifierPrefix'] = ['LEGACY1234']
        value['Entitlements']['application-identifier'] = 'LEGACY1234.local.liwei.Cubic'
        result = check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'testflight')
        check_entitlements(value['Entitlements'], 'ios', 'ABCDE12345', 'local.liwei.Cubic',
                           result['application_identifier_prefix'])
        value['ApplicationIdentifierPrefix'] = ['ABCDE12345']
        with self.assertRaisesRegex(ReleaseError, 'exact Bundle ID'):
            check_profile(value, 'ABCDE12345', 'local.liwei.Cubic', 'testflight')

    def test_identity_uses_certificate_ou_and_pinned_sha_not_cn_parentheses(self):
        der = b'fixture DER; decoded subject is supplied by mocked openssl'
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        def commands(argv, **kwargs):
            if argv[1] == 'find-identity':
                return f'1) {fingerprint} "Apple Development: Fixture (OTHERID123)"'
            if argv[1] == 'find-certificate':
                return ssl.DER_cert_to_PEM_cert(der)
            if '-subject' in argv:
                return 'subject=\n    CN=Apple Development: Fixture (OTHERID123)\n    OU=ABCDE12345\n'
            return 'Certificate will not expire'
        with patch('pipeline.run', side_effect=commands):
            identity_exists(fingerprint, 'ABCDE12345', 'Apple Development')
            with self.assertRaisesRegex(ReleaseError, 'OU'):
                identity_exists(fingerprint, 'OTHER12345', 'Apple Development')
            with self.assertRaisesRegex(ReleaseError, '类型'):
                identity_exists(fingerprint, 'ABCDE12345', 'Apple Distribution')

    def test_source_metadata_is_allowed_without_weakening_input_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / 'App.swift'
            file.write_text('committed input')
            expected = input_manifest(root)
            metadata = root / 'Core/.swiftpm/xcode'
            metadata.mkdir(parents=True)
            self.assertEqual(validate_input_manifest(root, expected), {})
            (metadata / 'workspace-state.json').write_text('{}')
            self.assertEqual(len(validate_input_manifest(root, expected)), 1)
            file.write_text('tampered source')
            with self.assertRaisesRegex(ReleaseError, '已改变'):
                validate_input_manifest(root, expected)
            file.write_text('committed input')
            file.chmod(file.stat().st_mode ^ 0o100)
            with self.assertRaisesRegex(ReleaseError, '已改变'):
                validate_input_manifest(root, expected)
            file.chmod(file.stat().st_mode ^ 0o100)
            (metadata / 'Injected.swift').write_text('new code')
            with self.assertRaisesRegex(ReleaseError, 'build input'):
                validate_input_manifest(root, expected)

    def test_receipt_commit_and_authoritative_input_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            source = build / 'source'; source.mkdir()
            (source / 'App.swift').write_text('committed input')
            expected = input_manifest(source)
            request = {'commit': 'a' * 40, 'platform': 'macos', 'channel': 'developer-id',
                       'team_id': 'ABCDE12345', 'version': '1.2.3', 'build_number': '42',
                       'ios_bundle_id': 'local.liwei.Cubic', 'macos_bundle_id': 'local.liwei.CubicMac',
                       'identity_scope': 'official'}
            receipt = {'schema_version': 1, 'request': request, 'unsigned': False, 'status': 'archived',
                       'build_configuration': 'Release', 'source': {
                           'commit': 'a' * 40, 'source_clean': True, 'source_kind': 'git-archive',
                           'input_roots': list(INPUTS), 'checks': {}, 'input_manifest': expected,
                           'exported_tree_sha256': manifest_hash(expected)}}
            def export(commit, target):
                target.mkdir(); (target / 'App.swift').write_text('committed input')
            with patch('pipeline.check_commit', return_value={'input_roots': list(INPUTS)}), \
                 patch('pipeline.export_source', side_effect=export), \
                 patch('pipeline.check_project', return_value={}):
                self.assertEqual(validate_build_receipt(receipt, build), request)
                receipt['source']['commit'] = 'b' * 40
                with self.assertRaisesRegex(ReleaseError, 'commit 不一致'):
                    validate_build_receipt(receipt, build)
                receipt['source']['commit'] = 'a' * 40
                (source / 'App.swift').write_text('tampered source')
                # Rehashing an edited input does not turn it into committed input.
                receipt['source']['input_manifest'] = input_manifest(source)
                receipt['source']['exported_tree_sha256'] = manifest_hash(receipt['source']['input_manifest'])
                with self.assertRaisesRegex(ReleaseError, '实际 commit'):
                    validate_build_receipt(receipt, build)

    def test_worker_ownership_tracks_detached_descendants_and_exact_scope(self):
        def row(parent, group, birth, command, executable='/tool/swift-frontend', cpu=1):
            return {'parent': parent, 'group': group, 'birth': birth, 'command': command,
                    'executable': executable, 'cpu': cpu, 'state': 'S'}
        root = '/tmp/Isolated Release source'
        baseline = {99: row(1, 99, 'old', '/tool/swift-frontend ' + root + '/File.swift')}
        tracker = ProcessTracker(100, baseline, (root,))
        rows = {100: row(1, 100, 'parent', 'xcodebuild'),
                101: row(100, 101, 'child', '/tool/swift-frontend child'),
                102: row(1, 102, 'worker', '/tool/swift-frontend ' + root + '/File.swift'),
                103: row(1, 103, 'unrelated', '/tool/swift-frontend ' + root + '-other/File.swift'),
                104: row(1, 104, 'service', '/service ' + root, '/tool/XCBBuildService'),
                99: baseline[99]}
        self.assertEqual(set(tracker.observe(rows)), {100, 101, 102})
        rows[101]['parent'] = 1
        del rows[100]
        self.assertIn(101, tracker.observe(rows))
        rows[101]['birth'] = 'reused pid'
        self.assertNotIn(101, tracker.observe(rows))
        rows[102]['state'] = 'Z'
        self.assertNotIn(102, tracker.observe(rows))

    def test_canonical_scope_accepts_verified_macos_lexical_alias(self):
        lexical = Path('/tmp/Isolated Release source')
        tracker = ProcessTracker(100, {}, (lexical.resolve(),))
        row = {'parent': 1, 'group': 101, 'birth': 'new',
               'command': '/tool/swift-frontend ' + str(lexical) + '/App.swift',
               'executable': '/tool/swift-frontend', 'cpu': 5, 'state': 'S'}
        self.assertIn(101, tracker.observe({101: row}))
        row['command'] = '/tool/swift-frontend ' + str(lexical) + '-other/App.swift'
        self.assertEqual(ProcessTracker(100, {}, (lexical.resolve(),)).observe({101: row}), {})

    def test_group_permission_error_cannot_skip_detached_child_signal(self):
        rows = {100: {'parent': 1, 'group': 100, 'birth': 'parent', 'command': 'parent',
                      'executable': '/tool/parent', 'cpu': 1, 'state': 'S'},
                101: {'parent': 100, 'group': 101, 'birth': 'child', 'command': 'child',
                      'executable': '/tool/child', 'cpu': 1, 'state': 'S'}}
        tracker = ProcessTracker(100, {})
        tracker.observe(rows)
        rows[101]['parent'] = 1
        proc = Mock(pid=100)
        with patch('common.process_snapshot', return_value=rows), \
             patch('common.os.killpg', side_effect=PermissionError('real error fixture')) as group, \
             patch('common.os.kill') as child:
            errors = tracker.signal_owned(9, proc)
            proc.poll.assert_called_once()
            group.assert_called_once_with(100, 9)
            child.assert_called_once_with(101, 9)
            self.assertTrue(errors)
        rows[100]['state'] = 'Z'
        with patch('common.process_snapshot', return_value=rows), \
             patch('common.os.killpg') as group, patch('common.os.kill') as child:
            self.assertEqual(tracker.signal_owned(9, proc), [])
            group.assert_not_called()
            child.assert_called_once_with(101, 9)

    def test_failed_baseline_disables_scope_ownership_and_unsafe_roots(self):
        tracker = ProcessTracker(100, None, ('/tmp/isolated',))
        row = {'parent': 1, 'group': 101, 'birth': 'new', 'command': '/tool/swift-frontend /tmp/isolated/App.swift',
               'executable': '/tool/swift-frontend', 'cpu': 5, 'state': 'S'}
        self.assertEqual(tracker.observe({101: row}), {})
        with self.assertRaisesRegex(ReleaseError, '隔离'):
            ProcessTracker(100, {}, ('/',))

    def test_nonzero_exit_and_output_survive_cleanup_failure(self):
        with patch.object(ProcessTracker, 'cleanup', side_effect=ReleaseError('cleanup fixture failure')):
            with self.assertRaises(ReleaseError) as result:
                run([sys.executable, '-c', "import sys; print('primary tool output'); sys.exit(7)"])
            self.assertIn('exit 7', str(result.exception))
            self.assertIn('primary tool output', str(result.exception))
            self.assertIn('cleanup fixture failure', str(result.exception))
            with self.assertRaisesRegex(ReleaseError, '^cleanup fixture failure$'):
                run([sys.executable, '-c', 'pass'])

    def test_privacy_requires_timestamp_as_well_as_defaults(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'PrivacyInfo.xcprivacy'
            path.write_bytes(plistlib.dumps({'NSPrivacyTracking': False, 'NSPrivacyCollectedDataTypes': [],
                'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults',
                                             'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}]}))
            with self.assertRaisesRegex(ReleaseError, 'FileTimestamp'):
                privacy(path)

    def test_missing_final_resource_fails_before_signature_assessment(self):
        request = {'platform': 'macos', 'macos_bundle_id': 'local.liwei.CubicMac', 'version': '1.2.3',
                   'build_number': '42', 'team_id': 'ABCDE12345'}
        lock = {'minimum_os': '26.0', 'cloudkit_info_key': 'CubicCloudKitCapability', 'cloudkit_info_value': 'disabled'}
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / 'Cubic.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'local.liwei.CubicMac', 'CFBundleShortVersionString': '1.2.3',
                'CFBundleVersion': '42', 'LSMinimumSystemVersion': '26.0', 'CubicBuildConfiguration': 'Release',
                'CubicCloudKitCapability': 'disabled', 'NSCalendarsFullAccessUsageDescription': 'QA'}))
            with patch('validate.run') as commands, self.assertRaisesRegex(ReleaseError, 'asset catalog'):
                check_bundle(app, request, lock, 'a' * 40)
            commands.assert_not_called()

    def test_hash_tracks_resource_and_symlink_changes(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            (path / 'resource').write_bytes(b'original')
            initial = tree_hash(path)
            (path / 'resource').write_bytes(b'changed')
            self.assertNotEqual(initial, tree_hash(path))
            previous = tree_hash(path)
            (path / 'link').symlink_to('resource')
            self.assertNotEqual(previous, tree_hash(path))

    def test_zip_traversal_is_blocked(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'malformed.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('../outside', b'bad')
            with self.assertRaisesRegex(ReleaseError, '不安全'):
                safe_zip(path)

    def manifest_fixture(self, artifact):
        return {'schema_version': 1, 'source': {'source_clean': True, 'source_kind': 'git-archive', 'commit': 'a' * 40},
                'platform': 'ios', 'channel': 'testflight', 'build_configuration': 'Release', 'minimum_os': '26.0',
                'architectures': ['arm64'], 'version': '1.2.3', 'build_number': '42', 'release_ready': False,
                'artifact': {'filename': artifact.name, 'bytes': artifact.stat().st_size,
                             'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest()},
                'privacy': {'status': 'pass'}, 'capability': {'cloudkit': False},
                'toolchain': dict.fromkeys(('xcode', 'iphoneos_sdk', 'macosx_sdk', 'swift', 'xcodegen',
                                           'xcodebuildmcp', 'lock_sha256'), 'fixture')}

    def test_manifest_detects_modified_artifact_and_private_device_list(self):
        with tempfile.TemporaryDirectory() as root:
            artifact = Path(root) / 'Cubic.ipa'
            artifact.write_bytes(b'original export')
            value = self.manifest_fixture(artifact)
            validate_manifest(value, artifact)
            value['profile'] = {'devices': ['PRIVATE-UDID']}
            with self.assertRaisesRegex(ReleaseError, '私密字段'):
                validate_manifest(value, artifact)
            del value['profile']
            artifact.write_bytes(b'modified export')
            with self.assertRaisesRegex(ReleaseError, 'SHA-256'):
                validate_manifest(value, artifact)

    def test_manifest_cannot_claim_release_ready_without_independent_qa(self):
        with tempfile.TemporaryDirectory() as root:
            artifact = Path(root) / 'Cubic.ipa'
            artifact.write_bytes(b'export')
            value = self.manifest_fixture(artifact)
            value['release_ready'] = True
            with self.assertRaisesRegex(ReleaseError, 'release_ready'):
                validate_manifest(value, artifact)


if __name__ == '__main__':
    unittest.main()
