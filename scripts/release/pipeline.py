"""Read-only preflight, isolated archive, and explicit local channel export."""
import datetime as dt
import hashlib
import os
from pathlib import Path
import re
import shutil
import ssl
import tempfile
import uuid

from common import ROOT, ReleaseError, load_json, require, run, sha256, tree_hash, write_json
from manifest import validate_manifest
from source import (check_commit, check_project, export_source, inspect_source,
                    input_manifest, manifest_hash, validate_input_manifest)
from validate import check_bundle, check_profile, profile, safe_zip

CHANNELS = {'macos': {'developer-id'}, 'ios': {'testflight', 'app-store', 'ad-hoc'}}


def toolchain(lock_path):
    lock = load_json(lock_path)
    commands = {
        'xcode': ['xcodebuild', '-version'],
        'iphoneos_sdk': ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'],
        'macosx_sdk': ['xcrun', '--sdk', 'macosx', '--show-sdk-version'],
        'swift': ['xcrun', 'swift', '--version'],
        'xcodegen': ['xcodegen', '--version'],
        'xcodebuildmcp': ['xcodebuildmcp', '--version']}
    receipt = {}
    errors = []
    for key, argv in commands.items():
        try:
            value = run(argv).strip()
            if key == 'xcodebuildmcp':
                value = value.splitlines()[-1]
            if key == 'swift':
                require(lock['swift_contains'] in value, 'Swift 版本不匹配')
            else:
                require(value == lock[key], f'{key} 版本不匹配，要求 {lock[key]!r}，实际 {value!r}')
            receipt[key] = value
        except ReleaseError as exc:
            errors.append(str(exc))
    try:
        run(['xcodebuild', '-checkFirstLaunchStatus'])
    except ReleaseError:
        errors.append('Xcode license/first launch 未完成；由操作者在 Xcode 完成，不自动安装或接受 license')
    require(not errors, '\n'.join(errors))
    receipt['lock_sha256'] = sha256(lock_path)
    return lock, receipt


def read_devices(path):
    devices = load_json(path) if path else []
    require(isinstance(devices, list) and all(isinstance(x, str) and re.fullmatch(r'[A-Za-z0-9-]{20,64}', x)
                                            for x in devices), 'devices JSON 必须为合法 device ID 字符串数组')
    require(len(devices) == len(set(devices)), 'devices JSON 不接受重复项')
    return devices


def identity_exists(identity, team, kind):
    require(bool(re.fullmatch(r'[0-9A-Fa-f]{40}', identity or '')), 'identity 必须为 Keychain certificate SHA-1，不能含账户名')
    values = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
    require(any(re.search(r'\b' + identity.upper() + r'\b', line.upper())
                for line in values.splitlines()), f'缺可用 {kind} identity/private key；由操作者配置 Keychain')
    certificates = run(['security', 'find-certificate', '-a', '-p'])
    selected = None
    for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
        der = ssl.PEM_cert_to_DER_cert(pem)
        if hashlib.sha1(der).hexdigest().upper() == identity.upper():
            selected = der
            break
    require(selected is not None, 'Keychain 缺所选 SHA-1 对应 certificate')
    with tempfile.TemporaryDirectory(prefix='Cubic certificate ') as directory:
        path = Path(directory) / 'certificate.der'
        path.write_bytes(selected)
        subject = run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', path,
                       '-noout', '-subject', '-nameopt', 'sep_multiline'])
        fields = {}
        for line in subject.splitlines():
            match = re.fullmatch(r'\s*(OU|CN)\s*=\s*(.*?)\s*', line)
            if match:
                fields.setdefault(match[1], []).append(match[2])
        require(fields.get('OU') == [team], 'certificate subject OU 与 Team 不符')
        require(len(fields.get('CN', [])) == 1 and fields['CN'][0].startswith(kind + ':'),
                f'certificate 类型不是 {kind}')
        run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', path, '-noout', '-checkend', '0'])


def installed_profile(value, selected_path):
    directories = (Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
                   Path.home() / 'Library/MobileDevice/Provisioning Profiles')
    uuid = value.get('UUID', '')
    require(bool(uuid), 'profile 缺 UUID')
    candidates = [directory / f'{variant}.mobileprovision' for directory in directories
                  for variant in {uuid, uuid.lower(), uuid.upper()}]
    selected = Path(selected_path).expanduser().resolve()
    if selected.parent in directories:
        candidates.append(selected)
    require(any(path.is_file() and sha256(path) == sha256(selected) for path in candidates),
            'profile 未安装到 Xcode provisioning profile 目录，或安装内容与输入不符；由操作者导入，CLI 不修改')


def signing(args, request):
    if args.unsigned:
        return {'status': 'unsigned-source-check', 'distributable': False}
    kind = 'Developer ID Application' if request['platform'] == 'macos' else 'Apple Distribution'
    identity_exists(args.identity, request['team_id'], kind)
    result = {'status': 'local-assets-pass', 'distribution_certificate_sha1': args.identity.upper()}
    if request['platform'] == 'ios':
        identity_exists(args.archive_identity, request['team_id'], 'Apple Development')
        archive = profile(args.archive_profile)
        check_profile(archive, request['team_id'], request['ios_bundle_id'], 'archive-development', identity=args.archive_identity)
        installed_profile(archive, args.archive_profile)
        distribution = profile(args.profile)
        result['profile'] = check_profile(distribution, request['team_id'], request['ios_bundle_id'],
                                          request['channel'], read_devices(args.devices), args.test_window_days,
                                          args.identity)
        installed_profile(distribution, args.profile)
        result['archive_profile_uuid'] = archive['UUID']
        result['distribution_profile_uuid'] = distribution['UUID']
    return result


def preflight(args, request):
    errors = []
    report = {'request': request, 'status': 'blocked', 'network_submitted': False,
              'distributable': False, 'checks': {}}
    for name, action in (
        ('source', lambda: inspect_source(request['commit'], args.unsigned)),
        ('toolchain', lambda: toolchain(args.toolchain)[1]),
        ('signing', lambda: signing(args, request))):
        try:
            report['checks'][name] = action()
        except (ReleaseError, OSError, ValueError, KeyError) as exc:
            report['checks'][name] = {'status': 'blocked', 'reason': str(exc)}
            errors.append(f'{name}: {exc}')
    if not errors:
        report['status'] = 'pass-local-preflight'
    if args.report:
        write_json(Path(args.report).resolve(), report)
    print(__import__('json').dumps(report, ensure_ascii=False, indent=2))
    require(not errors, '\n'.join(errors))
    return report


def fresh_output(output, request, stage):
    output = Path(output).expanduser().resolve()
    for input_name in ('Core', 'CubicApp', 'CubicMac', 'Cubic.xcodeproj', 'Tests', 'CubicUITests', 'CubicMacUITests'):
        require(not output.is_relative_to(ROOT / input_name), 'output 不能放在 build source 输入内')
    output.mkdir(parents=True, exist_ok=True)
    prefix = f'{request["version"]}-{request["build_number"]}-{request["platform"]}-{request["channel"]}-{stage}-'
    return Path(tempfile.mkdtemp(prefix=prefix, dir=output))


def export_options(request, identity, profile_uuid=None):
    method = {'developer-id': 'developer-id', 'testflight': 'app-store-connect',
              'app-store': 'app-store-connect', 'ad-hoc': 'release-testing'}[request['channel']]
    options = {'method': method, 'destination': 'export', 'signingStyle': 'manual',
               'teamID': request['team_id'], 'signingCertificate': identity,
               'manageAppVersionAndBuildNumber': False}
    if request['platform'] == 'ios':
        require(bool(profile_uuid), 'iOS export 缺 distribution profile UUID')
        options['provisioningProfiles'] = {request['ios_bundle_id']: profile_uuid}
        if request['channel'] in ('testflight', 'app-store'):
            options['uploadSymbols'] = True
            options['testFlightInternalTestingOnly'] = False
        else:
            options['thinning'] = '<none>'
    return options


def build(args, request):
    preflight(args, request)
    directory = fresh_output(args.output_dir, request, 'build')
    print(f'BUILD_DIR={directory}', flush=True)
    try:
        lock, tools = toolchain(args.toolchain)
        source_receipt = check_commit(request['commit'])
        source = directory / 'source'
        export_source(request['commit'], source)
        source_receipt['checks'] = check_project(source, args.unsigned)
        source_receipt['input_manifest'] = input_manifest(source)
        source_receipt['exported_tree_sha256'] = manifest_hash(source_receipt['input_manifest'])
        assets = signing(args, request)
        shutil.copyfile(args.toolchain, directory / 'toolchain-lock.json')
        platform = request['platform']
        scheme = 'CubicMac' if platform == 'macos' else 'Cubic'
        bundle = request['macos_bundle_id'] if platform == 'macos' else request['ios_bundle_id']
        argv = ['xcodebuild', '-project', source / 'Cubic.xcodeproj', '-scheme', scheme,
                '-configuration', 'Release', '-sdk', 'macosx' if platform == 'macos' else 'iphoneos',
                '-destination', 'generic/platform=macOS' if platform == 'macos' else 'generic/platform=iOS',
                '-derivedDataPath', directory / 'DerivedData', '-archivePath', directory / 'Cubic.xcarchive',
                '-disableAutomaticPackageResolution', '-skipPackageUpdates',
                f'MARKETING_VERSION={request["version"]}', f'CURRENT_PROJECT_VERSION={request["build_number"]}',
                f'PRODUCT_BUNDLE_IDENTIFIER={bundle}', f'DEVELOPMENT_TEAM={request["team_id"]}',
                'ONLY_ACTIVE_ARCH=NO', 'ARCHS=arm64 x86_64' if platform == 'macos' else 'ARCHS=arm64',
                'CUBIC_CLOUD_ENTITLEMENTS=', 'CUBIC_CLOUDKIT_CAPABILITY=disabled', 'CODE_SIGN_STYLE=Manual']
        if args.unsigned:
            argv += ['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO']
        else:
            argv += [f'CODE_SIGN_IDENTITY={args.identity if platform == "macos" else args.archive_identity}']
            if platform == 'ios':
                argv += [f'PROVISIONING_PROFILE_SPECIFIER={assets["archive_profile_uuid"]}']
            else:
                argv += ['OTHER_CODE_SIGN_FLAGS=--timestamp', 'ENABLE_HARDENED_RUNTIME=YES']
        argv += ['archive']
        run(argv, cwd=source, log=directory / 'archive.log', activity=True,
            activity_roots=(source, directory / 'DerivedData'))
        receipt = {'schema_version': 1, 'request': request, 'unsigned': args.unsigned,
                   'source': source_receipt, 'toolchain': tools, 'signing': assets,
                   'archive_tree_sha256': tree_hash(directory / 'Cubic.xcarchive'),
                   'tooling_sha256': tree_hash(Path(__file__).parent), 'build_configuration': 'Release',
                   'status': 'archived', 'distributable': False}
        write_json(directory / 'build-receipt.json', receipt)
    except Exception as exc:
        write_json(directory / 'failure.json', {'status': 'blocked', 'reason': str(exc), 'stage': 'build'})
        raise
    return directory


def validate_build_receipt(receipt, build_dir):
    require(receipt.get('schema_version') == 1, '不支持的 build receipt schema')
    require(receipt.get('status') == 'archived' and type(receipt.get('unsigned')) is bool,
            'receipt 缺有效 archived/unsigned 状态')
    request = receipt.get('request', {})
    source = receipt.get('source', {})
    commit = request.get('commit')
    require(isinstance(commit, str) and re.fullmatch(r'[0-9a-f]{40}', commit), 'request commit 无效')
    require(source.get('commit') == commit, 'request/source commit 不一致')
    require(source.get('source_clean') is True and source.get('source_kind') == 'git-archive',
            'source clean/kind 不符合 committed input 合约')
    require(receipt.get('build_configuration') == 'Release', 'receipt configuration 不是 Release')
    require(request.get('platform') in CHANNELS and
            request.get('channel') in CHANNELS[request['platform']], 'receipt channel/platform 不一致')
    require(bool(re.fullmatch(r'[A-Z0-9]{10}', request.get('team_id', ''))), 'receipt Team 无效')
    require(bool(re.fullmatch(r'\d+\.\d+\.\d+', request.get('version', ''))) and
            bool(re.fullmatch(r'[1-9]\d*', request.get('build_number', ''))), 'receipt version/build 无效')
    for key in ('ios_bundle_id', 'macos_bundle_id'):
        require(bool(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', request.get(key, ''))),
                f'receipt Bundle ID 无效: {key}')
    require(request.get('identity_scope') in ('official', 'developer-copy'), 'receipt identity scope 无效')
    if request['identity_scope'] == 'official':
        require(request['ios_bundle_id'] == 'local.liwei.Cubic' and
                request['macos_bundle_id'] == 'local.liwei.CubicMac', '官方 receipt Bundle identity 错误')
    authoritative = check_commit(commit)
    require(source.get('input_roots') == authoritative['input_roots'], 'receipt input roots 不一致')
    with tempfile.TemporaryDirectory(prefix='Cubic verify committed input ') as directory:
        pristine = Path(directory) / 'source'
        export_source(commit, pristine)
        checks = check_project(pristine, receipt.get('unsigned', False))
        expected = input_manifest(pristine)
    require(source.get('checks') == checks, 'receipt source checks 与 commit 不一致')
    require(source.get('input_manifest') == expected and
            source.get('exported_tree_sha256') == manifest_hash(expected),
            'receipt 输入清单与实际 commit 不一致')
    generated = validate_input_manifest(Path(build_dir) / 'source', expected)
    if generated:
        print(f'已核对 {len(generated)} 个 Xcode generated metadata 文件', flush=True)
    return request


def package(args):
    build_dir = Path(args.build_dir).expanduser().resolve()
    receipt = load_json(build_dir / 'build-receipt.json')
    request = validate_build_receipt(receipt, build_dir)
    require(receipt['status'] == 'archived' and not receipt['unsigned'], 'unsigned/archive 未完成：不能 package')
    require(tree_hash(Path(__file__).parent) == receipt['tooling_sha256'], 'release tooling 已改变，重新 archive 或审查新工具')
    require(tree_hash(build_dir / 'Cubic.xcarchive') == receipt['archive_tree_sha256'], 'archive 已改变，拒绝伪造来源')
    lock, tools = toolchain(build_dir / 'toolchain-lock.json')
    require(tools == receipt['toolchain'], 'package 工具链与 archive receipt 不符')
    identity_exists(args.identity, request['team_id'],
                    'Developer ID Application' if request['platform'] == 'macos' else 'Apple Distribution')
    devices = read_devices(args.devices)
    profile_uuid = None
    if request['platform'] == 'ios':
        value = profile(args.profile)
        check_profile(value, request['team_id'], request['ios_bundle_id'], request['channel'],
                      devices, args.test_window_days, args.identity)
        installed_profile(value, args.profile)
        profile_uuid = value['UUID']
    require(not args.notary or request['platform'] == 'macos', '--notary 仅适用于 Mac')
    require(not args.notary or args.notary_profile, '--notary 需要已配置的 Keychain credential profile 名')
    require(not args.resume_notary_from or (args.notary and args.notary_submission_id),
            'resume 需要 --notary、--notary-profile 与 --notary-submission-id')
    require(not args.notary_submission_id or args.resume_notary_from, 'submission ID 只能用于明确的 resume attempt')
    directory = fresh_output(args.output_dir, request, 'package')
    print(f'PACKAGE_DIR={directory}', flush=True)
    try:
        import plistlib
        options = export_options(request, args.identity, profile_uuid)
        with (directory / 'ExportOptions.plist').open('xb') as stream:
            plistlib.dump(options, stream)
        if args.resume_notary_from:
            previous = Path(args.resume_notary_from).expanduser().resolve()
            binding = load_json(previous / 'notary-input.json')
            require(binding['request'] == request and binding['archive_tree_sha256'] == receipt['archive_tree_sha256'],
                    'resume 候选与 archive 输入不一致')
            require(sha256(previous / 'notary-upload.zip') == binding['upload_sha256'], '先前 notary upload 已改变')
            shutil.copyfile(previous / 'notary-upload.zip', directory / 'notary-upload.zip')
            safe_zip(directory / 'notary-upload.zip')
            run(['ditto', '-x', '-k', directory / 'notary-upload.zip', directory / 'export'])
        else:
            run(['xcodebuild', '-exportArchive', '-archivePath', build_dir / 'Cubic.xcarchive',
                 '-exportPath', directory / 'export', '-exportOptionsPlist', directory / 'ExportOptions.plist'],
                cwd=directory, log=directory / 'export.log', activity=True,
                activity_roots=(build_dir / 'Cubic.xcarchive', directory / 'export'))
        notary = {'status': 'not-submitted'}
        if request['platform'] == 'macos':
            apps = list((directory / 'export').glob('*.app'))
            require(len(apps) == 1, 'Mac export 必须且仅包含一个 app')
            app = apps[0]
            check_bundle(app, request, lock, args.identity)
            if args.notary:
                if not args.resume_notary_from:
                    run(['ditto', '-c', '-k', '--keepParent', app, directory / 'notary-upload.zip'])
                binding = {'request': request, 'archive_tree_sha256': receipt['archive_tree_sha256'],
                           'upload_sha256': sha256(directory / 'notary-upload.zip')}
                write_json(directory / 'notary-input.json', binding)
                if args.resume_notary_from:
                    submission_id = args.notary_submission_id
                else:
                    raw = run(['xcrun', 'notarytool', 'submit', directory / 'notary-upload.zip',
                               '--keychain-profile', args.notary_profile, '--output-format', 'json',
                               '--no-wait'], log=directory / 'notary-submit.log')
                    submitted = __import__('json').loads(raw)
                    write_json(directory / 'notary-submission.json', submitted)
                    submission_id = submitted['id']
                submission_id = str(uuid.UUID(submission_id))
                raw = run(['xcrun', 'notarytool', 'info', submission_id,
                           '--keychain-profile', args.notary_profile, '--output-format', 'json'],
                          log=directory / 'notary-info.log')
                notary = __import__('json').loads(raw)
                write_json(directory / 'notary-receipt.json', notary)
                require(str(notary.get('status', '')).lower() == 'accepted', 'notary 未 Accepted；保留回执，渠道 blocked')
                run(['xcrun', 'notarytool', 'log', submission_id, directory / 'notary-log.json',
                     '--keychain-profile', args.notary_profile], log=directory / 'notary-log-command.log')
                notarized_log = load_json(directory / 'notary-log.json')
                require(notarized_log.get('sha256') == binding['upload_sha256'] and
                        notarized_log.get('jobId') == submission_id and notarized_log.get('status') == 'Accepted',
                        'notary log 与同一 upload hash/Accepted submission 不匹配')
                run(['xcrun', 'stapler', 'staple', app], log=directory / 'staple.log')
                run(['xcrun', 'stapler', 'validate', app], log=directory / 'staple-validate.log')
            artifact = directory / 'Cubic.zip'
            # Rebuild ZIP after staple. Validate the app extracted from this exact ZIP.
            run(['ditto', '-c', '-k', '--keepParent', app, artifact])
        else:
            ipas = list((directory / 'export').glob('*.ipa'))
            require(len(ipas) == 1, 'iOS export 必须且仅包含一个 IPA')
            artifact = directory / 'Cubic.ipa'
            shutil.copyfile(ipas[0], artifact)
        safe_zip(artifact)
        final = directory / 'final-extracted'
        run(['ditto', '-x', '-k', artifact, final])
        apps = list(final.glob('*.app')) if request['platform'] == 'macos' else list((final / 'Payload').glob('*.app'))
        require(len(apps) == 1, '最终包必须且仅含一个 App')
        validated = check_bundle(apps[0], request, lock, args.identity, devices, args.test_window_days)
        target = 'CubicMac' if request['platform'] == 'macos' else 'Cubic'
        require(validated['privacy']['content_sha256'] == receipt['source']['checks']['privacy'][target]['content_sha256'],
                '最终 privacy resource 与隔离 commit 中声明不一致')
        local_ready = False
        if request['platform'] == 'macos' and args.notary:
            run(['xcrun', 'stapler', 'validate', apps[0]], log=directory / 'final-staple.log')
            run(['spctl', '--assess', '--type', 'execute', '--verbose=4', apps[0]], log=directory / 'final-spctl.log')
            local_ready = True
        manifest = {'schema_version': 1, 'source': receipt['source'], 'toolchain': tools,
                    'tooling_sha256': receipt['tooling_sha256'], 'build_configuration': 'Release',
                    'channel': request['channel'], 'platform': request['platform'],
                    'identity_scope': request['identity_scope'], **validated,
                    'artifact': {'filename': artifact.name, 'sha256': sha256(artifact), 'bytes': artifact.stat().st_size},
                    'notarization': {'status': notary.get('status'), 'submission_id': notary.get('id')},
                    'local_distribution_checks': 'pass' if local_ready else 'candidate-only',
                    'release_ready': False, 'acceptance': {'status': 'not-run', 'reference': args.acceptance_reference},
                    'channel_receipt': {'status': 'not-uploaded' if request['platform'] == 'ios' else 'local-only',
                                        'processing_build_identifier': None},
                    'created_utc': dt.datetime.now(dt.timezone.utc).isoformat()}
        validate_manifest(manifest, artifact)
        write_json(directory / 'release-manifest.json', manifest)
        print(f'MANIFEST={directory / "release-manifest.json"}')
    except Exception as exc:
        write_json(directory / 'failure.json', {'status': 'blocked', 'reason': str(exc), 'stage': 'package'})
        raise
    return directory
