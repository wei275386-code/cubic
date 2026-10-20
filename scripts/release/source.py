"""Committed input export and XcodeGen consistency check."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import tarfile
import tempfile

from common import EXCLUDED, INPUTS, ROOT, ReleaseError, require, run, sha256


def check_commit(commit, repo=ROOT):
    require(bool(re.fullmatch(r'[0-9a-f]{40}', commit or '')), '必须提供完整 40 位 commit SHA')
    actual = run(['git', 'rev-parse', '--verify', commit + '^{commit}'], cwd=repo).strip()
    require(actual == commit, 'commit 必须解析为同一个完整 SHA')
    dirty = run(['git', 'status', '--porcelain', '--untracked-files=all', '--', *INPUTS], cwd=repo)
    require(not dirty, '构建输入存在未提交改动；先由整合者 review/commit，不把工作区伪标为 clean commit')
    names = run(['git', 'ls-tree', '-r', '--name-only', commit, '--', *INPUTS], cwd=repo).splitlines()
    for item in INPUTS:
        require(any(name == item or name.startswith(item + '/') for name in names), f'commit 缺输入: {item}')
    return {'commit': commit, 'source_clean': True, 'source_kind': 'git-archive',
            'input_roots': list(INPUTS)}


def export_source(commit, target, repo=ROOT):
    target = Path(target)
    target.mkdir()
    archive = target.parent / 'source.tar'
    run(['git', 'archive', '--format=tar', '-o', archive, commit, '--', *INPUTS], cwd=repo)
    try:
        with tarfile.open(archive) as stream:
            for member in stream.getmembers():
                parts = Path(member.name).parts
                require(not Path(member.name).is_absolute() and '..' not in parts, '不安全 archive 路径')
                require(not member.issym() and not member.islnk() and
                        (member.isfile() or member.isdir()), f'不支持的源码输入: {member.name}')
                if any(part in EXCLUDED or 'DerivedData' in part for part in parts):
                    continue
                stream.extract(member, target)
    finally:
        archive.unlink()
    require((target / 'Core/Package.swift').is_file(), 'Core package 不完整')


def privacy(path):
    require(path.is_file(), f'缺 PrivacyInfo.xcprivacy: {path}')
    with path.open('rb') as stream:
        value = plistlib.load(stream)
    require(isinstance(value, dict), 'Privacy manifest root 必须为 dictionary')
    require(type(value.get('NSPrivacyTracking')) is bool, 'Privacy tracking 必须为 Bool')
    require(isinstance(value.get('NSPrivacyCollectedDataTypes'), list), '缺 privacy data types 数组')
    apis = value.get('NSPrivacyAccessedAPITypes')
    require(isinstance(apis, list), '缺 required reason API 数组')
    found = {}
    for api in apis:
        require(isinstance(api, dict), 'API 声明必须为 dictionary')
        reasons = api.get('NSPrivacyAccessedAPITypeReasons')
        require(isinstance(reasons, list) and reasons and
                all(isinstance(r, str) and re.fullmatch(r'[A-Z0-9]{4}\.[0-9]+', r) for r in reasons),
                'API reason 必须为非空合法用途码数组')
        found[api.get('NSPrivacyAccessedAPIType')] = reasons
    for kind in ('NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPICategoryFileTimestamp'):
        require(kind in found, f'缺 required reason 类别: {kind}')
    return {'status': 'pass', 'sha256': sha256(path),
            'content_sha256': hashlib.sha256(plistlib.dumps(value, sort_keys=True)).hexdigest(), 'api_reasons': found,
            'scope': 'structure-and-required-categories; usage review required'}


def check_project(source, unsigned=False):
    source = Path(source)
    project = source / 'Cubic.xcodeproj'
    expected = {p.relative_to(project).as_posix(): p.read_bytes()
                for p in [project / 'project.pbxproj', *sorted((project / 'xcshareddata/xcschemes').glob('*.xcscheme'))]}
    require(len(expected) >= 4, '缺 project 或 shared schemes')
    run(['xcodegen', 'generate', '--spec', source / 'project.yml', '--project', source,
         '--project-root', source], cwd=source)
    for name, data in expected.items():
        require((project / name).read_bytes() == data, f'source/spec 不一致: {name}；在发行 commit 前重新生成')
    actual_names = {p.relative_to(project).as_posix() for p in (project / 'xcshareddata/xcschemes').glob('*.xcscheme')}
    require(actual_names == set(expected) - {'project.pbxproj'}, 'scheme 集合不一致')
    # plutil reads OpenStep plist. Resolve file references using each group path.
    objects = json.loads(run(['plutil', '-convert', 'json', '-o', '-', project / 'project.pbxproj']))['objects']
    for obj in objects.values():
        require(obj.get('isa') != 'XCRemoteSwiftPackageReference', '本期不允许远程 package 隐式解析/网络输入')
        if obj.get('isa') == 'XCLocalSwiftPackageReference':
            package = source / obj.get('relativePath', '')
            require(package.resolve().is_relative_to(source.resolve()) and (package / 'Package.swift').is_file(),
                    'local package 缺失或越出隔离源码')
    resources = {}
    def visit(identifier, parent):
        obj = objects[identifier]
        kind = obj.get('isa')
        path = obj.get('path', '')
        base = source if obj.get('sourceTree') == 'SOURCE_ROOT' else parent
        resolved = base / path
        if kind in ('PBXGroup', 'PBXFileSystemSynchronizedRootGroup'):
            for child in obj.get('children', []):
                visit(child, resolved)
        elif kind == 'PBXFileReference' and obj.get('sourceTree') in ('<group>', 'SOURCE_ROOT'):
            require(resolved.exists(), f'缺 project source/resource: {resolved.relative_to(source)}')
            require(resolved.resolve().is_relative_to(source.resolve()), 'project 引用越出隔离源码')
            resources[identifier] = resolved
    project_object = next(v for v in objects.values() if v.get('isa') == 'PBXProject')
    visit(project_object['mainGroup'], source)
    results = {}
    for target in (v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') in ('Cubic', 'CubicMac')):
        manifests = []
        for phase_id in target.get('buildPhases', []):
            phase = objects[phase_id]
            if phase.get('isa') == 'PBXResourcesBuildPhase':
                for file_id in phase.get('files', []):
                    file_path = resources.get(objects[file_id].get('fileRef'))
                    if file_path and file_path.name == 'PrivacyInfo.xcprivacy':
                        manifests.append(file_path)
        try:
            require(len(manifests) == 1, f'{target["name"]} 必须且仅能打包一份 privacy manifest')
            results[target['name']] = privacy(manifests[0])
        except ReleaseError as exc:
            if not unsigned:
                raise
            results[target['name']] = {'status': 'blocked', 'reason': str(exc)}
    require(set(results) == {'Cubic', 'CubicMac'}, '缺两端 App target')
    # Asset files must exist; no dependency on ignored build products.
    for contents in source.rglob('Contents.json'):
        if '.xcassets' not in str(contents):
            continue
        value = json.loads(contents.read_text())
        for item in value.get('images', []):
            if 'filename' in item:
                require((contents.parent / item['filename']).is_file(), f'缺 asset: {contents}')
    return {'generator': 'byte-identical', 'privacy': results}


def inspect_source(commit, unsigned=False):
    receipt = check_commit(commit)
    with tempfile.TemporaryDirectory(prefix='Cubic release source ') as temporary:
        source = Path(temporary) / 'source'
        export_source(commit, source)
        receipt['checks'] = check_project(source, unsigned)
    return receipt


# Xcode owns these metadata trees. Committed files here are still pinned below.
GENERATED_METADATA = ('Core/.swiftpm/xcode/',
                      'Cubic.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/',
                      'Cubic.xcodeproj/project.xcworkspace/xcuserdata/',
                      'Cubic.xcodeproj/xcuserdata/')


def input_manifest(root):
    """Pin all exported input files, including their executable/permission bits."""
    root = Path(root)
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), f'源码不接受 symlink: {path}')
        if path.is_file():
            result[path.relative_to(root).as_posix()] = {
                'sha256': sha256(path), 'mode': path.stat().st_mode & 0o7777}
        else:
            require(path.is_dir(), f'源码不接受特殊文件: {path}')
    return result


def manifest_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def validate_input_manifest(root, expected):
    actual = input_manifest(root)
    for name, value in expected.items():
        require(actual.get(name) == value, f'隔离 source 已改变: {name}')
    generated = {}
    for name, value in actual.items():
        if name not in expected:
            require(any(name.startswith(prefix) for prefix in GENERATED_METADATA),
                    f'隔离 source 新增未授权输入: {name}')
            # Generated metadata cannot introduce executable build inputs.
            require(not value['mode'] & 0o111 and Path(name).suffix not in
                    {'.swift', '.m', '.mm', '.c', '.h', '.xcprivacy', '.xcconfig'},
                    f'generated metadata 不接受 build input: {name}')
            generated[name] = value
    return generated
