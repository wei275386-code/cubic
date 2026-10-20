"""Offline public receipt checks for QA intake; no signature trust claim."""
import json
from pathlib import Path
import re

from common import require, sha256


def validate_manifest(value, artifact):
    artifact = Path(artifact)
    source = value['source']
    require(value.get('schema_version') == 1 and source.get('source_clean') is True,
            'manifest schema/source clean 无效')
    require(source.get('source_kind') == 'git-archive' and
            bool(re.fullmatch(r'[0-9a-f]{40}', source.get('commit', ''))), 'manifest 缺完整 committed source')
    platform = value['platform']
    channels = {'macos': {'developer-id'}, 'ios': {'testflight', 'app-store', 'ad-hoc'}}
    require(platform in channels and value['channel'] in channels[platform], 'manifest channel/platform 不符')
    require(value['build_configuration'] == 'Release' and value['minimum_os'] == '26.0',
            'manifest configuration/minimum OS 不符本期契约')
    require(set(value['architectures']) == ({'arm64', 'x86_64'} if platform == 'macos' else {'arm64'}),
            'manifest 架构不符')
    require(bool(re.fullmatch(r'\d+\.\d+\.\d+', value['version'])) and
            bool(re.fullmatch(r'[1-9]\d*', value['build_number'])), 'manifest version/build 无效')
    record = value['artifact']
    require(artifact.is_file() and record['filename'] == artifact.name and record['bytes'] == artifact.stat().st_size
            and record['sha256'] == sha256(artifact), 'artifact filename/size/SHA-256 与 manifest 不符')
    require(value['privacy']['status'] == 'pass' and value['capability']['cloudkit'] is False,
            'manifest privacy/capability 未通过')
    for key in ('xcode', 'iphoneos_sdk', 'macosx_sdk', 'swift', 'xcodegen', 'xcodebuildmcp', 'lock_sha256'):
        require(bool(value['toolchain'].get(key)), f'manifest 缺工具链 receipt: {key}')
    forbidden = {'password', 'private_key', 'apple_id', 'email', 'udid', 'udids', 'devices',
                 'provisioneddevices', 'device_ids', 'provisioningprofiles', 'notary_profile'}
    def public(item):
        if isinstance(item, dict):
            require(not any(str(key).lower() in forbidden for key in item), '公开 manifest 含私密字段')
            for child in item.values():
                public(child)
        elif isinstance(item, list):
            for child in item:
                public(child)
    public(value)
    require(value.get('release_ready') is False, '本地 tooling 不接受伪造 release_ready；统一 QA 另签结果记录')
    return {'status': 'pass-offline-receipt', 'signature_trust': 'not-checked', 'release_ready': False}
