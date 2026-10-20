"""Release I/O: stdlib only, argv subprocesses, bounded diagnostics."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
INPUTS = ('project.yml', 'Cubic.xcodeproj', 'Core', 'CubicApp', 'CubicMac',
          'CubicUITests', 'CubicMacUITests', 'Tests')
EXCLUDED = {'.scratch', 'evidence', 'logs', 'dist', 'downloads', 'files',
            'node_modules', '.git', '.build', 'build', '__pycache__', '.xcodebuildmcp'}


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


WORKERS = {'swift-frontend', 'swiftc', 'swift-driver', 'swift', 'clang', 'clang++',
           'ld', 'actool', 'ibtool', 'metal', 'metallib', 'swiftpm-testing-helper', 'xctest'}


def process_snapshot():
    """Read birth identity, ancestry, executable and full argv without a shell."""
    try:
        rows = subprocess.run(['/bin/ps', '-ww', '-axo',
                               'pid=,ppid=,pgid=,time=,stat=,lstart=,command='],
                              capture_output=True, text=True, timeout=2, check=True).stdout
        executables = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,comm='],
                                     capture_output=True, text=True, timeout=2, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    names = {}
    for line in executables.splitlines():
        columns = line.split(None, 1)
        if len(columns) == 2 and columns[0].isdigit():
            names[int(columns[0])] = columns[1]
    result = {}
    for line in rows.splitlines():
        columns = line.split(None, 10)
        if len(columns) != 11:
            continue
        try:
            pid, parent, group = map(int, columns[:3])
            cpu = sum(float(value) * 60 ** index
                      for index, value in enumerate(reversed(columns[3].split(':'))))
            result[pid] = {'parent': parent, 'group': group, 'cpu': cpu,
                           'state': columns[4], 'birth': ' '.join(columns[5:10]), 'command': columns[10],
                           'executable': names.get(pid, '')}
        except ValueError:
            continue
    return result


class ProcessTracker:
    """Track descendants and new build workers with exact isolated path scope.

    A shared build service or a pre-existing process is never scope-owned.
    Retain birth identity when a worker changes PGID or is reparented.
    """
    def __init__(self, group, baseline, roots=()):
        self.group = group
        self.baseline = {(pid, row['birth']) for pid, row in (baseline or {}).items()}
        self.scope_enabled = baseline is not None
        self.owned = {}
        self.roots = []
        for root in roots:
            lexical = Path(os.path.abspath(root))
            path = lexical.resolve()
            require(path not in (Path('/'), Path.home(), ROOT), 'worker scope 必须为明确隔离 build/package 路径')
            spellings = {str(lexical), str(path)}
            # macOS canonical system symlinks can appear in tool argv either way.
            for canonical, alias in (('/private/tmp', '/tmp'), ('/private/var', '/var'), ('/private/etc', '/etc')):
                if str(path) == canonical or str(path).startswith(canonical + '/'):
                    candidate = Path(alias + str(path)[len(canonical):])
                    if candidate.resolve() == path:
                        spellings.add(str(candidate))
            for spelling in sorted(spellings):
                self.roots.append(re.compile(r'(?<![^\s=])' + re.escape(spelling) + r'(?=/|\s|$)'))

    def observe(self, rows):
        if rows is None:
            return {}
        for pid, row in rows.items():
            if row['group'] == self.group and (pid, row['birth']) not in self.baseline:
                self.owned[pid] = row['birth']
            elif self.scope_enabled and (pid, row['birth']) not in self.baseline and \
                 Path(row['executable']).name in WORKERS and \
                 any(pattern.search(row['command']) for pattern in self.roots):
                self.owned[pid] = row['birth']
        # Fixed point handles descendant rows appearing before their parent.
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                parent = rows.get(row['parent'])
                if self.owned.get(pid) != row['birth'] and parent and \
                   self.owned.get(row['parent']) == parent['birth'] and \
                   (pid, row['birth']) not in self.baseline:
                    self.owned[pid] = row['birth']
                    changed = True
        return {pid: (row['cpu'], row['executable'] or row['command'])
                for pid, row in rows.items() if self.owned.get(pid) == row['birth'] and not row.get('state', '').startswith('Z')}

    def activity(self):
        return self.observe(process_snapshot())

    def signal_owned(self, sig, proc):
        # Reap an exited leader before signalling: macOS may report EPERM for
        # a zombie-only group. A live child's group remains independently owned.
        proc.poll()
        rows = process_snapshot()
        self.observe(rows)
        errors = []
        group_live = [row for row in (rows or {}).values()
                      if row['group'] == self.group and not row.get('state', '').startswith('Z')]
        if rows is None or group_live:
            try:
                os.killpg(self.group, sig)
            except ProcessLookupError:
                pass
            except OSError as exc:
                errors.append(f'主 group signal 失败: {exc}')
        # A group error must never prevent birth-matched detached child cleanup.
        for pid, row in (rows or {}).items():
            if self.owned.get(pid) == row['birth'] and row['group'] != self.group and \
               not row.get('state', '').startswith('Z'):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
                except OSError as exc:
                    errors.append(f'owned worker {pid} signal 失败: {exc}')
        if rows is None and any(pid != proc.pid for pid in self.owned):
            errors.append('无法读取 process birth identity；无法确认独立 worker 清理')
        return errors

    def cleanup(self, proc):
        errors = self.signal_owned(signal.SIGTERM, proc)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            remaining = self.activity()
            if not remaining:
                break
            time.sleep(0.1)
        errors.extend(self.signal_owned(signal.SIGKILL, proc))
        if proc.poll() is None:
            proc.wait(timeout=2)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            rows = process_snapshot()
            remaining = self.observe(rows)
            if rows is None and any(pid != proc.pid for pid in self.owned):
                errors.append('无法确认独立 worker 最终状态')
                break
            if not remaining:
                break
            time.sleep(0.1)
        require(not remaining, '仍有已归属 worker 存活；拒绝把清理未完成标为成功')
        require(not errors, '；'.join(errors))


def run(argv, cwd=None, log=None, activity=False, activity_roots=()):
    """Stop after 20 s without stdout or measured CPU progress; cap at 30 min.

    CPU sampling is explicit for long builds/tests, not enabled for other tools.
    """
    argv = [str(x) for x in argv]
    baseline = process_snapshot()
    tracker = ProcessTracker(None, baseline, activity_roots)
    try:
        proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as exc:
        raise ReleaseError(f'不能执行 {argv[0]}: {exc}') from exc
    tracker.group = proc.pid
    data = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    started = last_output = last_sample = time.monotonic()
    previous_activity = {}
    current = {}
    last_observation = 0
    failure = None
    try:
        while selector.get_map():
            events = selector.select(timeout=1)
            if events:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    selector.unregister(proc.stdout)
                else:
                    data.extend(chunk)
                    last_output = time.monotonic()
                    if log:
                        # Full log stays on disk; retain at most 1 MiB for diagnostics/JSON.
                        if len(data) > 1024 * 1024:
                            del data[:-1024 * 1024]
                        with Path(log).open('ab') as stream:
                            stream.write(chunk)
                        print(chunk.decode(errors='replace'), end='', flush=True)
            now = time.monotonic()
            if now - last_observation >= 1:
                current = tracker.activity()
                last_observation = now
            if activity and now - last_sample >= 5 and selector.get_map():
                progressed = [(pid, value) for pid, value in current.items()
                              if value[0] > previous_activity.get(pid, (0, ''))[0]]
                previous_activity = current
                last_sample = now
                if progressed:
                    last_output = time.monotonic()
                    diagnostic = ('[measured process activity] ' + '; '.join(
                        f'pid={pid} cpu={value[0]:.2f}s command={value[1]}'
                        for pid, value in progressed) + '\n')
                    if log:
                        with Path(log).open('ab') as stream:
                            stream.write(diagnostic.encode())
                    print(diagnostic, end='', flush=True)
            if selector.get_map() and (now - last_output >= 20 or now - started >= 1800):
                reason = '总时限 30 分钟' if now - started >= 1800 else '持续 20 秒无输出或可观察进展'
                raise ReleaseError(f'{argv[0]} {reason}，已停止；保留日志，不自动重试')
        proc.wait(timeout=20)
        output = data.decode(errors='replace')
        require(proc.returncode == 0,
                f'{argv[0]} exit {proc.returncode}: {output[-1600:]}')
    except BaseException as exc:
        failure = exc
        raise
    finally:
        selector.close()
        proc.stdout.close()
        try:
            tracker.cleanup(proc)
        except Exception as cleanup_error:
            if failure is not None:
                raise ReleaseError(f'{failure}；cleanup 失败: {cleanup_error}') from failure
            raise
    return output


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def tree_hash(root):
    """Include paths, file content, mode and symlink targets; exclude nothing."""
    root = Path(root)
    require(root.is_dir(), f'目录不存在: {root}')
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        value = os.readlink(path) if path.is_symlink() else sha256(path) if path.is_file() else 'directory'
        digest.update(json.dumps([relative, mode, value], ensure_ascii=False).encode())
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    require(not path.exists(), f'拒绝覆盖已有文件: {path}')
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def load_json(path):
    with Path(path).open(encoding='utf-8') as stream:
        return json.load(stream)
