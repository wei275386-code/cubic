#!/usr/bin/env python3
"""Cubic release CLI. All release input is explicit; no device/default lookup."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import sys

if sys.version_info < (3, 9):
    print('BLOCKED: release tooling 需要 Python 3.9+（发行者工具，不是接收方依赖）', file=sys.stderr)
    sys.exit(2)

from common import ROOT, ReleaseError, load_json, require
from manifest import validate_manifest
from pipeline import CHANNELS, build, export_options, package, preflight


def env(name, default=None):
    return os.environ.get('CUBIC_' + name, default)


def parser():
    command = argparse.ArgumentParser(description='Cubic committed-source release tooling；不会自动上传、安装依赖或注册设备')
    sub = command.add_subparsers(dest='command', required=True)
    for name in ('preflight', 'build'):
        child = sub.add_parser(name, help='只读本地检查' if name == 'preflight' else '隔离 Release archive（不安装/启动）')
        child.add_argument('--commit', default=env('COMMIT'))
        child.add_argument('--platform', choices=sorted(CHANNELS), default=env('PLATFORM'))
        child.add_argument('--channel', default=env('RELEASE_CHANNEL'))
        child.add_argument('--version', default=env('VERSION'))
        child.add_argument('--build-number', default=env('BUILD_NUMBER'))
        child.add_argument('--team-id', default=env('TEAM_ID'))
        child.add_argument('--ios-bundle-id', default=env('IOS_BUNDLE_ID', 'local.liwei.Cubic'))
        child.add_argument('--macos-bundle-id', default=env('MACOS_BUNDLE_ID', 'local.liwei.CubicMac'))
        child.add_argument('--identity-scope', choices=('official', 'developer-copy'), default='official')
        child.add_argument('--toolchain', type=Path, default=ROOT / 'config/release-toolchain.json')
        child.add_argument('--unsigned', action='store_true', help='仅源码/编译检查，禁止 package 与派发')
        child.add_argument('--identity', default=env('SIGNING_IDENTITY'), help='发行 certificate SHA-1')
        child.add_argument('--archive-identity', default=env('ARCHIVE_IDENTITY'), help='iOS archive development certificate SHA-1')
        child.add_argument('--archive-profile', default=env('ARCHIVE_PROFILE'), help='iOS archive development mobileprovision 路径')
        child.add_argument('--profile', default=env('DISTRIBUTION_PROFILE'), help='iOS distribution mobileprovision 路径')
        child.add_argument('--devices', default=env('DEVICES_JSON'), help='private Ad Hoc device JSON 文件路径')
        child.add_argument('--test-window-days', type=int, default=7)
        child.add_argument('--report', type=Path, help='显式新 report 文件；绝不覆盖')
        if name == 'build':
            child.add_argument('--output-dir', default=env('OUTPUT_DIR'), help='新候选父目录，必填')
    child = sub.add_parser('package', help='按 archive receipt 本地 export；--notary 才提交 Apple notary')
    child.add_argument('--build-dir', required=True)
    child.add_argument('--output-dir', default=env('OUTPUT_DIR'))
    child.add_argument('--identity', default=env('SIGNING_IDENTITY'))
    child.add_argument('--profile', default=env('DISTRIBUTION_PROFILE'))
    child.add_argument('--devices', default=env('DEVICES_JSON'))
    child.add_argument('--test-window-days', type=int, default=7)
    child.add_argument('--notary', action='store_true', help='显式网络提交；不等于发布')
    child.add_argument('--notary-profile', default=env('NOTARY_PROFILE'), help='已配置的 notarytool Keychain credential profile')
    child.add_argument('--resume-notary-from', help='先前 notary attempt 目录；复制同一 upload，绝不重新提交')
    child.add_argument('--notary-submission-id', help='resume 使用的真实 submission UUID')
    child.add_argument('--acceptance-reference', default='README.md#release-validation',
                       help='验收记录引用；引用不表示通过')
    child = sub.add_parser('export-options', help='输出 plist；不访问 Keychain/网络')
    child.add_argument('--platform', choices=sorted(CHANNELS), required=True)
    child.add_argument('--channel', required=True)
    child.add_argument('--team-id', required=True)
    child.add_argument('--identity', required=True)
    child.add_argument('--ios-bundle-id', default='local.liwei.Cubic')
    child.add_argument('--profile-uuid')
    child = sub.add_parser('verify-manifest', help='离线检查 public manifest 与 artifact hash；不宣称签名/渠道信任')
    child.add_argument('--manifest', required=True)
    child.add_argument('--artifact', required=True)
    return command


def request_from(args):
    fields = ('commit', 'platform', 'channel', 'version', 'build_number', 'team_id',
              'ios_bundle_id', 'macos_bundle_id', 'identity_scope')
    request = {name: getattr(args, name) for name in fields}
    for name, value in request.items():
        variable = 'RELEASE_CHANNEL' if name == 'channel' else name.upper()
        require(bool(value), f'缺必要参数 --{name.replace("_", "-")} / CUBIC_{variable}')
    require(request['channel'] in CHANNELS[request['platform']], 'channel/platform 组合不支持')
    require(bool(re.fullmatch(r'\d+\.\d+\.\d+', request['version'])), 'version 必须为三段数字')
    require(bool(re.fullmatch(r'[1-9]\d*', request['build_number'])), 'build number 必须为正整数，渠道递增另由 ASC 核对')
    require(bool(re.fullmatch(r'[A-Z0-9]{10}', request['team_id'])), 'Team ID 必须为 10 位大写字母/数字')
    for key in ('ios_bundle_id', 'macos_bundle_id'):
        require(bool(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', request[key])), f'无效 {key}')
    if request['identity_scope'] == 'official':
        require(request['ios_bundle_id'] == 'local.liwei.Cubic' and request['macos_bundle_id'] == 'local.liwei.CubicMac',
                '官方升级身份不可静默替换；自用副本请显式 --identity-scope developer-copy')
    require(args.test_window_days > 0, '测试窗口必须为正数')
    return request


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command == 'verify-manifest':
            print(json.dumps(validate_manifest(load_json(args.manifest), args.artifact), ensure_ascii=False))
        elif args.command == 'export-options':
            require(args.channel in CHANNELS[args.platform], 'channel/platform 组合不支持')
            require(bool(re.fullmatch(r'[A-Z0-9]{10}', args.team_id)), '无效 Team ID')
            require(bool(re.fullmatch(r'[0-9A-Fa-f]{40}', args.identity)), 'identity 必须为 certificate SHA-1')
            sys.stdout.buffer.write(plistlib.dumps(export_options(vars(args), args.identity, args.profile_uuid)))
        elif args.command == 'package':
            require(bool(args.output_dir), '缺 --output-dir / CUBIC_OUTPUT_DIR')
            require(args.test_window_days > 0, '测试窗口必须为正数')
            package(args)
        else:
            request = request_from(args)
            if args.command == 'build':
                require(bool(args.output_dir), '缺 --output-dir / CUBIC_OUTPUT_DIR')
                build(args, request)
            else:
                preflight(args, request)
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f'BLOCKED: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
