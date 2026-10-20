"""Validate the final export, never infer distribution from archive signing."""
import datetime as dt
import fnmatch
import hashlib
from pathlib import Path
import plistlib
import posixpath
import re
import zipfile

from common import ReleaseError, require, run
from source import privacy


def read_plist(path):
    with Path(path).open('rb') as stream:
        return plistlib.load(stream)


def output_plist(output):
    start = output.find('<?xml')
    end = output.find('</plist>', start)
    require(start >= 0 and end >= start, '工具没有返回完整 XML plist')
    return plistlib.loads(output[start:end + len('</plist>')].encode())


def profile(path):
    require(bool(path), '缺 provisioning profile 路径；需要 --profile/--archive-profile')
    require(Path(path).is_file(), f'缺 provisioning profile: {path}')
    return output_plist(run(['security', 'cms', '-D', '-i', path]))


def check_profile(value, team, bundle, channel, devices=(), window_days=0, identity=None):
    require(isinstance(window_days, int) and window_days >= 0,
            '测试窗口必须为非负整数天数，不能放宽 profile 到期检查')
    if channel == 'ad-hoc':
        require(window_days > 0, 'Ad Hoc 测试窗口必须至少为 1 天')
    require(team in value.get('TeamIdentifier', []), 'profile Team 不匹配')
    ent = value.get('Entitlements', {})
    app_id = ent.get('application-identifier', '')
    prefixes = value.get('ApplicationIdentifierPrefix', [])
    require(isinstance(prefixes, list) and prefixes and
            all(isinstance(p, str) and re.fullmatch(r'[A-Z0-9]{10}', p) for p in prefixes),
            'profile 缺合法 App Identifier Prefix')
    matched = [p for p in prefixes if app_id == p + '.' + bundle]
    require(len(matched) == 1, 'profile 需要 exact Bundle ID，不接受 wildcard 或额外层级')
    require(ent.get('com.apple.developer.team-identifier') == team, 'profile entitlement Team 不匹配')
    require(not value.get('ProvisionsAllDevices'), '不接受 enterprise profile')
    expiry = value.get('ExpirationDate')
    require(isinstance(expiry, dt.datetime), 'profile 缺到期时间')
    expiry = expiry.replace(tzinfo=dt.timezone.utc)
    require(expiry > dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=window_days),
            'profile 已过期或有效期不足测试窗口')
    if channel in ('testflight', 'app-store'):
        require(not value.get('ProvisionedDevices') and ent.get('get-task-allow') is False,
                'App Store Connect 需要 distribution profile，不能含 device 清单')
    elif channel == 'ad-hoc':
        require(bool(devices), 'Ad Hoc 必须提供非空目标设备集合')
        require(ent.get('get-task-allow') is False and bool(value.get('ProvisionedDevices')),
                'Ad Hoc 需要 device distribution profile')
        require(set(devices) <= set(value.get('ProvisionedDevices', [])), 'profile 未覆盖全部目标设备')
    elif channel == 'archive-development':
        require(ent.get('get-task-allow') is True and bool(value.get('ProvisionedDevices')),
                'archive profile 必须为显式 development profile')
    if identity:
        require(identity.upper() in {hashlib.sha1(cert).hexdigest().upper()
                                    for cert in value.get('DeveloperCertificates', [])},
                '所选 certificate 不在 profile 内')
    return {'application_identifier_prefix': matched[0], 'expiration_utc': expiry.isoformat(), 'test_window_days': window_days,
            'device_coverage': 'pass' if channel == 'ad-hoc' else 'not-applicable'}


def check_entitlements(ent, platform, team, bundle, app_identifier_prefix=None):
    require(ent.get('get-task-allow') is not True and
            ent.get('com.apple.security.get-task-allow') is not True,
            '最终 export 禁止 get-task-allow=true')
    require(not any('icloud' in key.lower() or 'ubiquity' in key.lower() for key in ent),
            '本期 Release 不允许 CloudKit/iCloud capability；文件目录使用用户授权')
    if platform == 'macos':
        for key in ('com.apple.security.app-sandbox', 'com.apple.security.files.user-selected.read-write',
                    'com.apple.security.files.bookmarks.app-scope',
                    'com.apple.security.personal-information.calendars', 'com.apple.security.network.client'):
            require(ent.get(key) is True, f'缺 Mac entitlement: {key}')
        permitted = {'com.apple.developer.team-identifier', 'com.apple.application-identifier',
                     'keychain-access-groups', 'get-task-allow', 'com.apple.security.get-task-allow',
                     'com.apple.security.app-sandbox', 'com.apple.security.files.user-selected.read-write',
                     'com.apple.security.files.bookmarks.app-scope',
                     'com.apple.security.personal-information.calendars', 'com.apple.security.network.client'}
        require(set(ent) <= permitted, 'Mac 最终 entitlement 超出最小能力清单')
    else:
        require(ent.get('application-identifier') == (app_identifier_prefix or team) + '.' + bundle,
                '最终 application identifier 错误')
        require(ent.get('com.apple.developer.team-identifier') == team, '最终 entitlement Team 错误')
        require(set(ent) <= {'application-identifier', 'com.apple.developer.team-identifier',
                             'keychain-access-groups', 'get-task-allow', 'beta-reports-active'},
                'iOS 最终 entitlement 超出本期最小能力清单')


def safe_zip(path):
    with zipfile.ZipFile(path) as archive:
        require(len(archive.infolist()) > 0, '空发行包')
        for item in archive.infolist():
            name = Path(item.filename)
            require(not name.is_absolute() and '..' not in name.parts and '\\' not in item.filename,
                    '发行包含不安全路径')
            if (item.external_attr >> 16) & 0o170000 == 0o120000:
                target = archive.read(item).decode()
                resolved = posixpath.normpath(str(name.parent / target))
                require(not target.startswith('/') and resolved != '..' and not resolved.startswith('../'),
                        '发行包含越界 symlink')


def check_binary(binary, platform, minimum):
    arches = run(['lipo', '-archs', binary]).strip().split()
    expected = {'arm64', 'x86_64'} if platform == 'macos' else {'arm64'}
    require(set(arches) == expected, f'架构不匹配: {arches}，要求 {sorted(expected)}')
    for arch in arches:
        commands = run(['otool', '-arch', arch, '-l', binary])
        build = re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)', commands)
        require(build and all(p == ('1' if platform == 'macos' else '2') and
                              tuple(map(int, v.split('.'))) == tuple(map(int, minimum.split('.')))
                              for p, v in build), f'Mach-O 平台或 minimum OS 错误: {binary.name}/{arch}')
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
        require(all(p.startswith(('@loader_path', '@executable_path', '/System/Library/', '/usr/lib/'))
                    for p in rpaths), '动态库 rpath 引用开发目录或非系统绝对路径')
    return sorted(arches)


def check_libraries(app):
    mach_magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                  b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
    for path in app.rglob('*'):
        if path.is_symlink():
            require(path.resolve().is_relative_to(app.resolve()), 'bundle symlink 越界')
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in mach_magic:
            continue
        dependencies = run(['otool', '-L', path])
        for line in dependencies.splitlines():
            if '(compatibility version' not in line:
                continue
            dependency = line.strip().split(' (compatibility version')[0]
            require(dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/',
                                           '@loader_path/', '@executable_path/')),
                    f'非系统或开发机动态库依赖: {dependency}')


def check_bundle(app, request, lock, signing_identity, devices=(), window_days=0):
    app = Path(app)
    mac = request['platform'] == 'macos'
    info = read_plist(app / ('Contents/Info.plist' if mac else 'Info.plist'))
    resources = app / 'Contents/Resources' if mac else app
    bundle = request['macos_bundle_id'] if mac else request['ios_bundle_id']
    for key, expected in (('CFBundleIdentifier', bundle), ('CFBundleShortVersionString', request['version']),
                          ('CFBundleVersion', request['build_number']),
                          ('LSMinimumSystemVersion' if mac else 'MinimumOSVersion', lock['minimum_os'])):
        require(info.get(key) == expected, f'最终 {key}: {info.get(key)!r}，要求 {expected!r}')
    require(info.get(lock['cloudkit_info_key']) == lock['cloudkit_info_value'],
            '最终 bundle 缺 Release CloudKit=disabled capability marker')
    require(info.get('CubicBuildConfiguration') == 'Release', '最终 bundle build configuration 不是 Release')
    require(bool(info.get('NSCalendarsFullAccessUsageDescription')), '缺 Calendar permission 用途说明')
    if not mac:
        require(info.get('UIDeviceFamily') == [1], '本期只支持 iPhone target family')
    require((resources / 'Assets.car').is_file(), '最终 bundle 缺编译后的 asset catalog')
    privacy_result = privacy(resources / 'PrivacyInfo.xcprivacy')
    executable = info.get('CFBundleExecutable', '')
    require(executable and Path(executable).name == executable, '无效 CFBundleExecutable')
    binary = app / 'Contents/MacOS' / executable if mac else app / executable
    arches = check_binary(binary, request['platform'], lock['minimum_os'])
    check_libraries(app)
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=4', app])
    display = run(['codesign', '--display', '--verbose=4', app])
    expected_authority = 'Developer ID Application:' if mac else 'Apple Distribution:'
    require(expected_authority in display, f'最终 export 不是 {expected_authority} identity')
    require(f'TeamIdentifier={request["team_id"]}' in display and f'Identifier={bundle}' in display,
            '最终 codesign Team/Bundle identity 不符')
    if mac:
        require(re.search(r'^CodeDirectory .*flags=.*runtime', display, re.M) and re.search(r'^Timestamp=.+', display, re.M),
                'Developer ID 需要 Hardened Runtime 与 secure timestamp')
    # Pin exported leaf certificate to the explicitly selected Keychain identity.
    cert_prefix = app.parent / 'validated-cert-'
    run(['codesign', '--display', '--extract-certificates', cert_prefix, app])
    cert_path = Path(str(cert_prefix) + '0')
    require(cert_path.is_file() and hashlib.sha1(cert_path.read_bytes()).hexdigest().upper() == signing_identity.upper(),
            '最终 signing certificate 与输入 SHA-1 不匹配')
    for cert in app.parent.glob('validated-cert-*'):
        cert.unlink()
    ent = output_plist(run(['codesign', '--display', '--entitlements', ':-', app]))
    profile_result = None
    if not mac:
        embedded = profile(app / 'embedded.mobileprovision')
        profile_result = check_profile(embedded, request['team_id'], bundle, request['channel'],
                                       devices, window_days, signing_identity)
        allowed = embedded['Entitlements']
        for key, value in ent.items():
            require(key in allowed, f'最终 entitlement 未由 profile 授权: {key}')
            candidates = allowed[key] if isinstance(allowed[key], list) else [allowed[key]]
            actual = value if isinstance(value, list) else [value]
            require(all(any(fnmatch.fnmatchcase(v, a) if isinstance(v, str) and isinstance(a, str)
                            else v == a for a in candidates) for v in actual), f'profile entitlement 值不匹配: {key}')
    check_entitlements(ent, request['platform'], request['team_id'], bundle,
                       profile_result['application_identifier_prefix'] if profile_result else None)
    return {'bundle_id': bundle, 'team_id': request['team_id'], 'version': request['version'],
            'build_number': request['build_number'], 'minimum_os': lock['minimum_os'],
            'architectures': arches, 'signature_type': expected_authority.rstrip(':'),
            'signature_integrity': 'pass', 'privacy': privacy_result,
            'capability': {'cloudkit': False}, 'profile': profile_result}
