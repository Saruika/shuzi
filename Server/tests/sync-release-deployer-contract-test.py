import hashlib
import importlib.machinery
import importlib.util
import fcntl
import json
import os
import signal
import stat
import sys
import tempfile
import time
from pathlib import Path


DEPLOYER = Path("Server/operations/deploy-shuzijun-sync-release")


def load_deployer():
    name = f"sync_release_deployer_{os.getpid()}_{id(object())}"
    loader = importlib.machinery.SourceFileLoader(name, str(DEPLOYER))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    return module


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def write_file(path: Path, payload: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(mode)


def tree_snapshot(root: Path) -> tuple[tuple[str, str, int, str], ...]:
    result: list[tuple[str, str, int, str]] = []
    if not root.exists():
        return tuple()
    for path in sorted(root.rglob("*"), key=lambda item: str(item.relative_to(root))):
        metadata = path.lstat()
        relative = str(path.relative_to(root))
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_symlink():
            result.append((relative, "symlink", mode, os.readlink(path)))
        elif path.is_dir():
            result.append((relative, "directory", mode, ""))
        elif path.is_file():
            result.append((relative, "file", mode, digest(path.read_bytes())))
        else:
            result.append((relative, "other", mode, ""))
    return tuple(result)


class Fixture:
    def __init__(self, temporary: str, module):
        self.module = module
        self.base = Path(temporary).resolve()
        self.root = self.base / "machine"
        self.external = self.base / "instrumentation"
        self.external.mkdir(mode=0o700)
        self.command_log = self.external / "commands.log"
        self.timer_state = self.external / "timer-state"
        self.timer_state.write_text("disabled\n", encoding="ascii")
        self.recovery_state = self.external / "recovery-state"
        self.recovery_state.write_text("", encoding="ascii")
        self.health_state = self.external / "health-state"
        self.health_state.write_text("healthy\n", encoding="ascii")
        self.job_state = self.external / "job-state"
        self.job_state.write_text("", encoding="ascii")
        self.bootstrap_crash = self.external / "bootstrap-crash"
        self.bootstrap_crash.write_text("", encoding="ascii")

        self.run = self.root / "run"
        self.stage_root = self.run / "shuzijun-sync-release"
        self.backup_stage = self.stage_root / "backup"
        self.primary_stage = self.stage_root / "primary"
        self.site = self.root / "var/www/html/shuzijun.com.cn"
        self.live_uploads = self.site / "wp-content/uploads"
        self.backup_parent = self.root / "var/backups"
        self.backup_root = self.backup_parent / "shuzijun-sync-release"
        self.sync_root = self.root / "var/lib/shuzijun-sync"
        self.operation_lock = self.sync_root / "site-operation.lock"
        self.sender_staging = self.sync_root / "sender-staging"
        self.highest_issued = self.sync_root / "highest-issued-generation"
        self.incoming = self.sync_root / "incoming"
        self.state = self.sync_root / "state"
        self.bin = self.root / "usr/local/sbin"
        self.systemd = self.root / "etc/systemd/system"
        self.sudoers = self.root / "etc/sudoers.d"
        self.config = self.root / "etc/shuzijun"
        self.tools = self.root / "tools"

        for path, mode in (
            (self.root, 0o700),
            (self.run, 0o700),
            (self.stage_root, 0o700),
            (self.backup_stage, 0o700),
            (self.primary_stage, 0o700),
            (self.root / "var/www", 0o700),
            (self.root / "var/www/html", 0o700),
            (self.site, 0o755),
            (self.site / "wp-content", 0o755),
            (self.live_uploads, 0o755),
            (self.backup_parent, 0o700),
            (self.root / "var", 0o700),
            (self.root / "var/lib", 0o700),
            (self.sync_root, 0o700),
            (self.incoming, 0o700),
            (self.state, 0o700),
            (self.root / "usr", 0o700),
            (self.root / "usr/local", 0o700),
            (self.bin, 0o700),
            (self.root / "etc", 0o700),
            (self.root / "etc/systemd", 0o700),
            (self.systemd, 0o700),
            (self.sudoers, 0o700),
            (self.config, 0o700),
            (self.tools, 0o700),
        ):
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(mode)

        self.accepted = self.state / "highest-accepted-generation"
        write_file(self.accepted, b"6\n", 0o600)

        self.role_verifier = self.bin / "verify-role"
        role_source = (
            "import sys\n"
            "raise SystemExit(0 if len(sys.argv) == 2 and sys.argv[1] in "
            "{'standby', 'authority'} else 9)\n"
        ).encode("utf-8")
        write_file(self.role_verifier, role_source, 0o755)

        self.systemctl = self.tools / "systemctl"
        systemctl_source = f"""#!{sys.executable}
import os
import pathlib
import sys
log = pathlib.Path({str(self.command_log)!r})
with log.open('a', encoding='utf-8') as stream:
    stream.write(' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['is-enabled', 'shuzijun-sync.timer']:
    state = pathlib.Path({str(self.timer_state)!r}).read_text(encoding='ascii').strip()
    print(state)
    raise SystemExit(0 if state == 'enabled' else 1)
guard_link = pathlib.Path({str(self.systemd / 'php8.3-fpm.service.requires/shuzijun-sync-fpm-guard.service')!r})
guard_target = pathlib.Path({str(self.systemd / 'shuzijun-sync-fpm-guard.service')!r})
unit_targets = {{
    'shuzijun-sync.timer': pathlib.Path({str(self.systemd / 'shuzijun-sync.timer')!r}),
    'shuzijun-sync.service': pathlib.Path({str(self.systemd / 'shuzijun-sync.service')!r}),
    'shuzijun-sync-preflight.service': pathlib.Path({str(self.systemd / 'shuzijun-sync-preflight.service')!r}),
    'shuzijun-sync-fpm-guard.service': guard_target,
}}
if sys.argv[1:3] == ['is-enabled', 'shuzijun-sync-fpm-guard.service']:
    if guard_link.is_symlink():
        print('enabled')
        raise SystemExit(0)
    if guard_target.exists():
        print('disabled')
        raise SystemExit(1)
    print('not-found')
    raise SystemExit(4)
if len(sys.argv) >= 3 and sys.argv[1] == 'is-enabled':
    target = unit_targets.get(sys.argv[2])
    if target is not None and not target.exists():
        print('not-found')
        raise SystemExit(4)
    print('disabled')
    raise SystemExit(1)
if len(sys.argv) >= 3 and sys.argv[1] == 'is-active' and sys.argv[2] in {{'php8.3-fpm.service', 'nginx.service', 'mysql.service'}}:
    healthy = pathlib.Path({str(self.health_state)!r}).read_text(encoding='ascii').strip() == 'healthy'
    print('active' if healthy else 'failed')
    raise SystemExit(0 if healthy else 3)
if len(sys.argv) >= 3 and sys.argv[1] == 'is-active':
    print('inactive')
    target = unit_targets.get(sys.argv[2])
    raise SystemExit(3 if target is None or target.exists() else 4)
if sys.argv[1:] == ['daemon-reload']:
    raise SystemExit(0)
if sys.argv[1:] == ['enable', 'shuzijun-sync-fpm-guard.service']:
    guard_link.parent.mkdir(mode=0o755, exist_ok=True)
    if not guard_link.is_symlink():
        os.symlink(str(guard_target), guard_link)
    raise SystemExit(0)
if sys.argv[1:] == ['show', 'shuzijun-sync-fpm-guard.service', '--property=RequiredBy', '--value']:
    print('php8.3-fpm.service')
    raise SystemExit(0)
if len(sys.argv) == 5 and sys.argv[1] == 'show' and sys.argv[4] == '--value':
    unit = sys.argv[2]
    property_name = sys.argv[3].split('=', 1)[1]
    if unit in {{'php8.3-fpm.service', 'nginx.service', 'mysql.service'}}:
        healthy = pathlib.Path({str(self.health_state)!r}).read_text(encoding='ascii').strip() == 'healthy'
        job = pathlib.Path({str(self.job_state)!r}).read_text(encoding='ascii').strip()
        values = (
            {{'LoadState': 'loaded', 'ActiveState': 'active', 'SubState': 'running', 'Result': 'success', 'MainPID': '4242', 'Job': job}}
            if healthy else
            {{'LoadState': 'loaded', 'ActiveState': 'failed', 'SubState': 'failed', 'Result': 'exit-code', 'MainPID': '0', 'Job': '999 start'}}
        )
    else:
        target = unit_targets.get(unit)
        loaded = target is None or target.exists()
        values = {{
            'LoadState': 'loaded' if loaded else 'not-found',
            'ActiveState': 'inactive',
            'SubState': 'dead',
            'Result': 'success',
            'MainPID': '0',
            'Job': '',
        }}
    print(values[property_name])
    raise SystemExit(0)
if len(sys.argv) >= 2 and sys.argv[1] == 'list-units':
    print(pathlib.Path({str(self.recovery_state)!r}).read_text(encoding='ascii'), end='')
    raise SystemExit(0)
if len(sys.argv) >= 2 and sys.argv[1] == 'list-jobs':
    raise SystemExit(0)
raise SystemExit(8)
""".encode("utf-8")
        write_file(self.systemctl, systemctl_source, 0o755)
        self.analyze = self.tools / "systemd-analyze"
        self.visudo = self.tools / "visudo"
        for tool in (self.analyze, self.visudo):
            write_file(tool, b"#!/bin/sh\nexit 0\n", 0o755)

        full = b"#!/bin/sh\nexit 0\n"
        source_verify = b"#!/bin/sh\nexit 0\n"
        guard = b"[Unit]\nDescription=fixture guard\n"
        sudoers = b"fixture ALL=(root:root) NOPASSWD: /bin/true\n"
        known_hosts = b"192.0.2.7 ssh-ed25519 AAAAFIXTURE\n"
        preflight_unit = b"[Service]\nType=oneshot\nExecStart=/bin/true\n"
        sync_unit = b"[Service]\nType=oneshot\nExecStart=/bin/true\n"
        sender = b"#!/bin/sh\nexit 0\n"

        receiver_target = self.bin / "apply-shuzijun-sync"
        receiver = f"""#!{sys.executable}
import hashlib
import json
import os
import pathlib
import re
import signal
import sys
import time
self_path = pathlib.Path(sys.argv[0])
if sys.argv[1:] == ['--bootstrap-state', '6']:
    release = pathlib.Path({str(self.sync_root / 'uploads-releases')!r})
    state = pathlib.Path({str(self.state)!r})
    live = pathlib.Path({str(self.live_uploads)!r})
    crash = pathlib.Path({str(self.bootstrap_crash)!r}).read_text(encoding='ascii').strip()
    def checkpoint(name):
        if crash == name:
            os.kill(os.getppid(), signal.SIGKILL)
            time.sleep(.1)
            raise SystemExit(137)
    stale = re.compile(r'(?:\\.highest-accepted\\.|\\.uploads-transaction\\.|\\.active-generation\\.|\\.active-release-v4\\.|\\.bootstrap-fpm-commit\\.)[0-9a-f]{{32}}')
    for entry in state.iterdir():
        if stale.fullmatch(entry.name):
            entry.unlink()
    if release.exists():
        if not release.is_dir() or any(release.iterdir()):
            raise SystemExit(8)
    else:
        release.mkdir(mode=0o700)
    checkpoint('after-root')
    checkpoint('before-active')
    live_meta = live.stat()
    evidence = hashlib.sha256(
        f'bootstrap-root-v4\\0{{6}}\\0{{live_meta.st_dev}}\\0{{live_meta.st_ino}}'.encode('ascii')
    ).hexdigest()
    release_id = hashlib.sha256(
        f'release-v4\\0{{6}}\\0{{evidence}}\\0{{live_meta.st_dev}}\\0{{live_meta.st_ino}}'.encode('ascii')
    ).hexdigest()
    publications = (
        (state / 'active-uploads-generation', b'6\\n'),
        (state / 'fpm-activation-guard.lease', b''),
        (state / 'fpm-activation-guard-v4.committed', f'6 {{release_id}} '.encode('ascii') + b'a' * 64 + b'\\n'),
        (state / 'active-release-v4.json', (json.dumps({{
            'evidence_sha256': evidence,
            'generation': 6,
            'release_id': release_id,
            'uploads_dev': live_meta.st_dev,
            'uploads_ino': live_meta.st_ino,
            'version': 4,
        }}, ensure_ascii=True, separators=(',', ':'), sort_keys=True) + '\\n').encode('ascii')),
    )
    for index, (path, payload) in enumerate(publications):
        if path.exists():
            if path.read_bytes() != payload:
                raise SystemExit(8)
        else:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.write(descriptor, payload)
            os.close(descriptor)
        if index == 0:
            checkpoint('after-active')
        elif index == 2:
            checkpoint('after-commit')
        elif index == 3:
            checkpoint('after-active-release')
    raise SystemExit(0)
if sys.argv[1:] == ['--attest']:
    print(hashlib.sha256(self_path.read_bytes()).hexdigest() + '  ' + str(self_path))
    raise SystemExit(0)
if sys.argv[1:] == ['--protocol']:
    print('shuzijun-sync-receiver-v4-transactional-uploads')
    raise SystemExit(0)
raise SystemExit(7)
""".encode("utf-8")

        self.payloads = {
            "verify-webroot-security": (full, 0o755),
            "shuzijun-sync-fpm-guard.service": (guard, 0o644),
            "shuzijun-sync-transport.sudoers": (sudoers, 0o440),
            "apply-shuzijun-sync": (receiver, 0o755),
            "verify-shuzijun-sync-source": (source_verify, 0o755),
            "shuzijun-sync-known-hosts": (known_hosts, 0o600),
            "shuzijun-sync-preflight.service": (preflight_unit, 0o644),
            "shuzijun-sync.service": (sync_unit, 0o644),
            "sync-to-backup": (sender, 0o755),
        }
        for name, (payload, mode) in self.payloads.items():
            stage = self.backup_stage if name in {
                "verify-webroot-security",
                "shuzijun-sync-fpm-guard.service",
                "shuzijun-sync-transport.sudoers",
                "apply-shuzijun-sync",
            } else self.primary_stage
            write_file(stage / name, payload, mode)
        write_file(self.primary_stage / "verify-webroot-security", full, 0o755)

        self.targets = {
            "verify-webroot-security": self.bin / "verify-shuzijun-webroot-security",
            "shuzijun-sync-fpm-guard.service": self.systemd / "shuzijun-sync-fpm-guard.service",
            "shuzijun-sync-transport.sudoers": self.sudoers / "shuzijun-sync-transport",
            "apply-shuzijun-sync": receiver_target,
            "verify-shuzijun-sync-source": self.bin / "verify-shuzijun-sync-source",
            "shuzijun-sync-known-hosts": self.config / "sync-known-hosts",
            "shuzijun-sync-preflight.service": self.systemd / "shuzijun-sync-preflight.service",
            "shuzijun-sync.service": self.systemd / "shuzijun-sync.service",
            "sync-to-backup": self.bin / "sync-to-backup",
        }
        for name, target in self.targets.items():
            mode = self.payloads[name][1]
            write_file(target, f"old:{name}\n".encode("utf-8"), mode)

        self.timer_unit = self.systemd / "shuzijun-sync.timer"
        write_file(self.timer_unit, b"old timer bytes\n", 0o644)

        self.ssh_key_parent = self.root / "root/.ssh"
        self.ssh_key_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.root / "root").chmod(0o700)
        self.ssh_key_parent.chmod(0o700)
        self.ssh_key = self.ssh_key_parent / "shuzijun_sync_ed25519"
        write_file(self.ssh_key, b"fixture-private-key\n", 0o600)
        self.remote_hash = self.external / "remote-receiver-hash"
        self.remote_hash.write_text(digest(receiver) + "\n", encoding="ascii")
        self.ssh = self.tools / "ssh"
        ssh_source = f"""#!{sys.executable}
import pathlib
import sys
command = sys.argv[-1]
if command == 'sudo /usr/local/sbin/apply-shuzijun-sync --attest':
    value = pathlib.Path({str(self.remote_hash)!r}).read_text(encoding='ascii').strip()
    print(value + '  /usr/local/sbin/apply-shuzijun-sync')
    raise SystemExit(0)
if command == 'sudo /usr/local/sbin/apply-shuzijun-sync --protocol':
    print('shuzijun-sync-receiver-v4-transactional-uploads')
    raise SystemExit(0)
raise SystemExit(9)
""".encode("utf-8")
        write_file(self.ssh, ssh_source, 0o755)
        self.configure_module()

    def configure_module(self) -> None:
        m = self.module
        m.ROOT_UID = os.geteuid()
        m.ROOT_GID = os.getegid()
        m.WEB_UID = os.geteuid()
        m.WEB_GID = os.getegid()
        m.SYMLINK_MODE = 0o755 if sys.platform == "darwin" else 0o777
        m.STAGE_ROOT = self.stage_root
        m.STAGES = {"backup": self.backup_stage, "primary": self.primary_stage}
        m.SITE = self.site
        m.LIVE_UPLOADS = self.live_uploads
        m.BACKUP_ROOT = self.backup_root
        m.ROLE_VERIFY = self.role_verifier
        m.ROLE_VERIFY_SHA256 = digest(self.role_verifier.read_bytes())
        m.ROLE_VERIFY_PARENT_PATHS = (
            self.root,
            self.root / "usr",
            self.root / "usr/local",
            self.bin,
        )
        m.PYTHON = Path(sys.executable)
        m.SYSTEMCTL = self.systemctl
        m.SYSTEMD_ANALYZE = self.analyze
        m.VISUDO = self.visudo
        m.SSH = self.ssh
        m.SSH_KEY = self.ssh_key
        m.SSH_KEY_PARENT_PATHS = (self.root / "root", self.ssh_key_parent)
        m.SYNC_ROOT = self.sync_root
        m.OPERATION_LOCK = self.operation_lock
        m.SENDER_STAGING_ROOT = self.sender_staging
        m.HIGHEST_ISSUED_GENERATION = self.highest_issued
        m.INCOMING_ROOT = self.incoming
        m.STATE_ROOT = self.state
        m.ACCEPTED_GENERATION = self.accepted
        m.UPLOADS_RELEASE_ROOT = self.sync_root / "uploads-releases"
        m.ACTIVE_UPLOADS_GENERATION = self.state / "active-uploads-generation"
        m.UPLOADS_TRANSACTION = self.state / "uploads-transaction.json"
        m.FPM_GUARD_LEASE = self.state / "fpm-activation-guard.lease"
        m.FPM_GUARD_ARMED = self.state / "fpm-activation-guard-v4.armed"
        m.FPM_GUARD_COMMIT = self.state / "fpm-activation-guard-v4.committed"
        m.ACTIVE_RELEASE_RECORD = self.state / "active-release-v4.json"
        m.ACTIVE_RELEASE_CONTRACT = "shuzijun-active-release-v4-bootstrap-root-live-inode"
        m.TIMER_OBSERVATION_PATHS = (
            self.timer_unit,
            self.systemd / "timers.target.wants/shuzijun-sync.timer",
            self.run / "systemd/system/timers.target.wants/shuzijun-sync.timer",
            self.root / "var/lib/systemd/timers/stamp-shuzijun-sync.timer",
        )
        m.GUARD_ENABLEMENT_DIR = self.systemd / "php8.3-fpm.service.requires"
        m.GUARD_ENABLEMENT_LINK = m.GUARD_ENABLEMENT_DIR / "shuzijun-sync-fpm-guard.service"
        m.GUARD_UNIT_TARGET = self.targets["shuzijun-sync-fpm-guard.service"]
        m.GUARD_ENABLEMENT_PATHS = (
            m.GUARD_ENABLEMENT_LINK,
            self.run / "systemd/system/php8.3-fpm.service.requires/shuzijun-sync-fpm-guard.service",
        )
        m.PRIMARY_FPM_FREEZE_ROOT = self.run / "shuzijun-sync"
        m.PRIMARY_FPM_FREEZE_MARKER = m.PRIMARY_FPM_FREEZE_ROOT / "primary-fpm-freeze.json"
        m.STAGE_PARENT_PATHS = (self.run, self.stage_root)
        m.TARGET_PARENT_PATHS = (
            self.root,
            self.root / "usr",
            self.root / "usr/local",
            self.bin,
            self.root / "etc",
            self.root / "etc/systemd",
            self.systemd,
            self.sudoers,
            self.config,
            self.root / "var",
            self.root / "var/lib",
            self.backup_parent,
            self.root / "var/www",
            self.root / "var/www/html",
        )
        m.RECEIVER_SHA256 = digest(self.payloads["apply-shuzijun-sync"][0])
        m.SENDER_SHA256 = digest(self.payloads["sync-to-backup"][0])
        m.FULL_VERIFY_SHA256 = digest(self.payloads["verify-webroot-security"][0])
        m.FPM_GUARD_SHA256 = digest(self.payloads["shuzijun-sync-fpm-guard.service"][0])
        m.SUDOERS_SHA256 = digest(self.payloads["shuzijun-sync-transport.sudoers"][0])
        m.SOURCE_VERIFY_SHA256 = digest(self.payloads["verify-shuzijun-sync-source"][0])
        m.KNOWN_HOSTS_SHA256 = digest(self.payloads["shuzijun-sync-known-hosts"][0])
        m.PREFLIGHT_SERVICE_SHA256 = digest(self.payloads["shuzijun-sync-preflight.service"][0])
        m.SYNC_SERVICE_SHA256 = digest(self.payloads["shuzijun-sync.service"][0])
        m.ASSETS = {
            "backup": (
                m.Asset("verify-webroot-security", self.targets["verify-webroot-security"], 0o755, m.FULL_VERIFY_SHA256),
                m.Asset("shuzijun-sync-fpm-guard.service", self.targets["shuzijun-sync-fpm-guard.service"], 0o644, m.FPM_GUARD_SHA256),
                m.Asset("shuzijun-sync-transport.sudoers", self.targets["shuzijun-sync-transport.sudoers"], 0o440, m.SUDOERS_SHA256),
                m.Asset("apply-shuzijun-sync", self.targets["apply-shuzijun-sync"], 0o755, m.RECEIVER_SHA256),
            ),
            "primary": (
                m.Asset("verify-webroot-security", self.targets["verify-webroot-security"], 0o755, m.FULL_VERIFY_SHA256),
                m.Asset("verify-shuzijun-sync-source", self.targets["verify-shuzijun-sync-source"], 0o755, m.SOURCE_VERIFY_SHA256),
                m.Asset("shuzijun-sync-known-hosts", self.targets["shuzijun-sync-known-hosts"], 0o600, m.KNOWN_HOSTS_SHA256),
                m.Asset("shuzijun-sync-preflight.service", self.targets["shuzijun-sync-preflight.service"], 0o644, m.PREFLIGHT_SERVICE_SHA256),
                m.Asset("shuzijun-sync.service", self.targets["shuzijun-sync.service"], 0o644, m.SYNC_SERVICE_SHA256),
                m.Asset("sync-to-backup", self.targets["sync-to-backup"], 0o755, m.SENDER_SHA256),
            ),
        }

    def write_primary_receipt(self, payload: bytes | None = None) -> None:
        # A fixture represents one node role at a time.  Standby-only runtime
        # state is removed before exercising the authority inventory contract.
        for directory in (self.incoming, self.state, self.sync_root / "uploads-releases"):
            if directory.exists():
                for child in directory.iterdir():
                    if child.is_dir() and not child.is_symlink():
                        raise AssertionError(f"unexpected nonempty fixture tree: {child}")
                    child.unlink()
                directory.rmdir()
        if not self.highest_issued.exists():
            write_file(self.highest_issued, b"6\n", 0o600)
        if payload is None:
            live = self.live_uploads.stat()
            evidence = self.module.bootstrap_evidence_sha256(
                6, live.st_dev, live.st_ino
            )
            release_id = self.module.active_release_identifier(
                6, evidence, live.st_dev, live.st_ino
            )
            active_payload = self.module.canonical_json({
                "evidence_sha256": evidence,
                "generation": 6,
                "release_id": release_id,
                "uploads_dev": live.st_dev,
                "uploads_ino": live.st_ino,
                "version": 4,
            })
            state = self.module.BootstrapState(
                "a" * 64, release_id, active_payload, {}
            )
            payload = self.module.standby_receipt_bytes(state, "b" * 64)
        write_file(
            self.primary_stage / "standby-first.receipt",
            payload,
            0o600,
        )

    def original_target_snapshot(self, node: str) -> dict[str, tuple[bytes, int] | None]:
        snapshot: dict[str, tuple[bytes, int] | None] = {}
        for path, _ in self.module.all_target_specs(node):
            metadata = self.module.lstat_or_none(path)
            if metadata is None:
                snapshot[str(path)] = None
            elif stat.S_ISREG(metadata.st_mode):
                snapshot[str(path)] = (path.read_bytes(), stat.S_IMODE(metadata.st_mode))
            elif stat.S_ISDIR(metadata.st_mode):
                snapshot[str(path)] = (b"<directory>", stat.S_IMODE(metadata.st_mode))
            else:
                raise AssertionError(f"unexpected fixture type: {path}")
        return snapshot


def expect_failure(callback, contains: str | None = None) -> Exception:
    try:
        callback()
    except Exception as error:
        if contains is not None:
            assert contains in str(error), str(error)
        return error
    raise AssertionError("operation unexpectedly succeeded")


def test_static_fail_closed_contract() -> None:
    text = DEPLOYER.read_text(encoding="utf-8")
    frozen_assets = (
        ("receiver", "RECEIVER_SHA256", "apply-shuzijun-sync", "0a28c89ef1ac427f6ac72e5268cb5aa0ed28169493aab64d05dd687a40e67e03"),
        ("sender", "SENDER_SHA256", "sync-to-backup", "a4e05f87426689673d5b741a88efcd6c8e35f856ab57f5b3ba78f56a004b4356"),
        ("FPM guard", "FPM_GUARD_SHA256", "shuzijun-sync-fpm-guard.service", "8d5b40388450c112c1f0ee84456ee960ae6a204323e8137ea0ec4f1c7a1d620e"),
        ("sudoers transport", "SUDOERS_SHA256", "shuzijun-sync-transport.sudoers", "7359fb403d227ffefe03e835deb73a03e5cfc720f70563be449a85d92267045e"),
        ("full verifier", "FULL_VERIFY_SHA256", "verify-webroot-security", "7e7a95a1cc7bb05aa6810a9d644950ddedb0274ce247499d5828a9180dcae7f2"),
        ("source verifier", "SOURCE_VERIFY_SHA256", "verify-shuzijun-sync-source", "b5e3cdde9b4cdf0ab7acee66fab991bbb3815419bfb0bf97f0283e7cbcfa04af"),
        ("known-hosts", "KNOWN_HOSTS_SHA256", "shuzijun-sync-known-hosts", "b48cc29b7506423ba402b954cb8c0fedc748706549ed704e84647b70a517d6f3"),
        ("preflight service", "PREFLIGHT_SERVICE_SHA256", "shuzijun-sync-preflight.service", "7e072f70b44f8d466e163ec91d7af8a2fc316698fd9257edc29647395ee17146"),
        ("sync service", "SYNC_SERVICE_SHA256", "shuzijun-sync.service", "943419bf84ad35f6f9ac857cf626e1c44f68a09c85d0bf56cc0cdc79c8b0e8b2"),
    )
    for _label, attribute, filename, expected in frozen_assets:
        assert f'{attribute} = "{expected}"' in text
        assert digest((DEPLOYER.parent / filename).read_bytes()) == expected
    assert 'ACTIVE_RELEASE_CONTRACT = "shuzijun-active-release-v4-bootstrap-root-live-inode"' in text
    assert "UNFROZEN_" not in text
    assert "ensure_release_frozen()" in text
    assert text.index("ensure_release_frozen()", text.index("def deploy(")) < text.index("create_backup(node)", text.index("def deploy("))
    assert 'Path("/run/deploy-shuzijun-sync-release")' in text
    assert 'Path("/run/shuzijun-sync-release")' in text
    assert '"backup": "standby", "primary": "authority"' in text
    assert "fcntl.LOCK_EX | fcntl.LOCK_NB" in text
    assert "with HeldLock(STAGE_ROOT)" in text
    assert "with HeldOperationLock() as operation_lock" in text
    assert 'OPERATION_LOCK = SYNC_ROOT / "site-operation.lock"' in text
    assert 'SENDER_STAGING_ROOT = SYNC_ROOT / "sender-staging"' in text
    assert 'FPM_GUARD_ARMED = STATE_ROOT / "fpm-activation-guard-v4.armed"' in text
    assert 'FPM_GUARD_COMMIT = STATE_ROOT / "fpm-activation-guard-v4.committed"' in text
    assert 'ACTIVE_RELEASE_RECORD = STATE_ROOT / "active-release-v4.json"' in text
    assert '"--bootstrap-state", str(BOOTSTRAP_GENERATION)' in text
    assert "BOOTSTRAP_GENERATION = 6" in text
    assert "os.replace(temporary, path)" in text
    assert "os.fsync(descriptor)" in text
    assert "fsync_directory(path.parent)" in text
    assert 'write_terminal(backup_dir, "committed"' in text
    assert 'write_terminal(backup_dir, "rolled-back"' in text
    assert 'write_terminal(backup_dir, "rollback-failed"' in text
    assert "backup-integrity.sha256" in text
    assert "standby-first.receipt" in text
    assert "sync timer must remain disabled" in text
    assert "start_new_session=True" in text
    assert "os.killpg(process.pid, signal.SIGTERM)" in text
    assert "os.killpg(process.pid, signal.SIGKILL)" in text
    assert '"-o", "StrictHostKeyChecking=yes"' in text
    assert '"-o", "IdentitiesOnly=yes"' in text
    assert "verify_remote_receiver_live()" in text
    assert "PRIMARY_FPM_FREEZE_MARKER" in text
    assert 'PRIMARY_RECOVERY_UNIT_GLOB = "shuzijun-primary-fpm-recovery-*.service"' in text
    assert "require_primary_recovery_clear()" in text
    assert '"list-jobs", PRIMARY_RECOVERY_UNIT_GLOB' in text
    assert 'state["job"] == ""' in text
    assert "require_unit_active_healthy(unit)" in text
    for required_unit in ("php8.3-fpm.service", "nginx.service", "mysql.service"):
        assert required_unit in text
    assert 'run_command([str(SYSTEMCTL), "enable", FPM_GUARD_SERVICE])' in text
    assert text.index("validate_bootstrap_result()", text.index("def post_install")) < text.index(
        'run_command([str(SYSTEMCTL), "enable", FPM_GUARD_SERVICE])',
        text.index("def post_install"),
    )
    for prohibited in (
        "systemctl start shuzijun-sync",
        "systemctl enable shuzijun-sync",
        "systemctl restart",
        "shuzijun-failover",
        "dnspod",
        "cloudflare",
        "rm -rf",
        "subprocess.run(['ssh'",
    ):
        assert prohibited not in text.lower()
    timer_name = "shuzijun-sync.timer"
    asset_block = text[text.index("def _asset_sets"):text.index("ASSETS = _asset_sets()")]
    assert timer_name not in asset_block
    primary_block = asset_block[asset_block.index('"primary":'):]
    assert 'Asset("verify-webroot-security"' in primary_block
    deploy_body = text[text.index("def deploy("):text.index("def usage(")]
    assert deploy_body.index("standby-first.receipt") < deploy_body.index(
        'write_terminal(backup_dir, "committed"'
    )

    original = load_deployer()
    assert original.FULL_VERIFY_SHA256 == digest(
        (DEPLOYER.parent / "verify-webroot-security").read_bytes()
    )
    assert original.ROLE_VERIFY_SHA256 == digest(
        (DEPLOYER.parent / "verify-account-authority-role.py").read_bytes()
    )
    original.ensure_release_frozen()
    gated = load_deployer()
    for label, attribute, _filename, expected in frozen_assets:
        setattr(gated, attribute, "not-a-frozen-digest")
        expect_failure(gated.ensure_release_frozen, label)
        setattr(gated, attribute, expected)
    gated.ACTIVE_RELEASE_CONTRACT = "wrong-active-release-contract"
    expect_failure(gated.ensure_release_frozen, "active-release-v4")


def test_metadata_symlink_hardlink_and_allowlists() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-metadata-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.write_primary_receipt()
        module.ensure_release_frozen()
        module.validate_stage("backup")
        module.validate_stage("primary")
        expect_failure(lambda: module.validate_role("backup", "authority"), "invalid node")
        expect_failure(lambda: module.validate_role("primary", "standby"), "invalid node")

        candidate = fixture.backup_stage / "apply-shuzijun-sync"
        candidate.chmod(0o700)
        expect_failure(lambda: module.validate_stage("backup"), "metadata")
        candidate.chmod(0o755)

        saved = fixture.external / "receiver-saved"
        candidate.rename(saved)
        candidate.symlink_to(saved)
        expect_failure(lambda: module.validate_stage("backup"))
        candidate.unlink()
        saved.rename(candidate)

        hardlink = fixture.external / "receiver-hardlink"
        os.link(candidate, hardlink)
        expect_failure(lambda: module.validate_stage("backup"), "metadata")
        hardlink.unlink()
        module.validate_stage("backup")

        extra = fixture.backup_stage / "._apply-shuzijun-sync"
        write_file(extra, b"apple-double", 0o755)
        expect_failure(lambda: module.validate_stage("backup"), "allowlist")
        extra.unlink()

        receipt_path = fixture.primary_stage / "standby-first.receipt"
        valid_receipt = receipt_path.read_bytes()
        receipt_path.write_bytes(b"forged\n")
        expect_failure(lambda: module.validate_stage("primary"), "invalid JSON")
        receipt_path.write_bytes(valid_receipt[:-1])
        expect_failure(lambda: module.validate_stage("primary"), "canonical")

        document = json.loads(valid_receipt.decode("ascii"))
        document["unexpected"] = True
        receipt_path.write_bytes(module.canonical_json(document))
        expect_failure(lambda: module.validate_stage("primary"), "canonical")

        document.pop("unexpected")
        document["active_release"]["uploads_ino"] += 1
        document["active_release_sha256"] = digest(
            module.canonical_json(document["active_release"])
        )
        receipt_path.write_bytes(module.canonical_json(document))
        expect_failure(lambda: module.validate_stage("primary"), "relationship")


def test_dry_run_is_read_only_and_timer_gate_is_dynamic() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-dry-run-") as temporary:
        fixture = Fixture(temporary, module)
        before = tree_snapshot(fixture.root)
        assert module.deploy("backup", "standby", "dry-run") is None
        assert tree_snapshot(fixture.root) == before
        assert not fixture.backup_root.exists()

        fixture.write_primary_receipt()
        before = tree_snapshot(fixture.root)
        assert module.deploy("primary", "authority", "dry-run") is None
        assert tree_snapshot(fixture.root) == before
        assert not fixture.backup_root.exists()

        fixture.timer_state.write_text("enabled\n", encoding="ascii")
        expect_failure(lambda: module.deploy("primary", "authority", "dry-run"), "disabled")
        assert not fixture.backup_root.exists()


def test_primary_stale_recovery_and_runtime_health_are_hard_gates() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-primary-gates-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.write_primary_receipt()

        module.PRIMARY_FPM_FREEZE_ROOT.mkdir(mode=0o700)
        write_file(module.PRIMARY_FPM_FREEZE_MARKER, b"stale\n", 0o600)
        expect_failure(
            lambda: module.deploy("primary", "authority", "dry-run"),
            "path must be absent",
        )
        assert not fixture.backup_root.exists()

        module.PRIMARY_FPM_FREEZE_MARKER.unlink()
        module.PRIMARY_FPM_FREEZE_ROOT.rmdir()

        fixture.recovery_state.write_text(
            "shuzijun-primary-fpm-recovery-deadbeef.service loaded failed failed\n",
            encoding="ascii",
        )
        expect_failure(
            lambda: module.deploy("primary", "authority", "dry-run"),
            "recovery watchdog",
        )
        assert not fixture.backup_root.exists()
        fixture.recovery_state.write_text("", encoding="ascii")

        fixture.health_state.write_text("failed\n", encoding="ascii")
        expect_failure(
            lambda: module.deploy("primary", "authority", "dry-run"),
            "not loaded/active/running/success",
        )
        assert not fixture.backup_root.exists()
        fixture.health_state.write_text("healthy\n", encoding="ascii")

        fixture.job_state.write_text("811 start\n", encoding="ascii")
        expect_failure(
            lambda: module.deploy("primary", "authority", "dry-run"),
            "not loaded/active/running/success",
        )
        assert not fixture.backup_root.exists()


def test_external_commands_have_a_real_timeout() -> None:
    module = load_deployer()
    module.COMMAND_TIMEOUT_SECONDS = 0.05
    error = expect_failure(
        lambda: module.run_command([
            sys.executable,
            "-c",
            "import time; time.sleep(2)",
        ])
    )
    assert isinstance(error, module.DeploymentError)
    assert "command timed out" in str(error)

    with tempfile.TemporaryDirectory(prefix="sync-release-process-group-") as temporary:
        marker = Path(temporary) / "grandchild-saw-term"
        child = (
            "import pathlib,signal,sys,time\n"
            "marker=pathlib.Path(sys.argv[1])\n"
            "signal.signal(signal.SIGTERM, lambda *_: (marker.write_text('term\\n'), sys.exit(0)))\n"
            "print('ready', flush=True)\n"
            "time.sleep(30)\n"
        )
        parent = (
            "import subprocess,sys,time\n"
            f"subprocess.Popen([sys.executable, '-c', {child!r}, sys.argv[1]])\n"
            "time.sleep(30)\n"
        )
        module.COMMAND_TIMEOUT_SECONDS = 0.25
        module.COMMAND_TERMINATION_GRACE_SECONDS = 1
        expect_failure(
            lambda: module.run_command([sys.executable, "-c", parent, str(marker)]),
            "command timed out",
        )
        assert marker.read_text(encoding="utf-8") == "term\n"

    module.COMMAND_TIMEOUT_SECONDS = 5
    expect_failure(
        lambda: module.run_command([
            sys.executable,
            "-c",
            "import os,signal,time; time.sleep(.1); "
            "os.kill(os.getppid(), signal.SIGTERM); time.sleep(30)",
        ]),
        "command interrupted by signal",
    )


def test_standby_first_commit_then_primary_and_integrity() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-sequence-") as temporary:
        fixture = Fixture(temporary, module)
        expect_failure(lambda: module.validate_stage("primary"), "allowlist")

        backup_timer = module.timer_snapshot()
        backup_dir = module.deploy("backup", "standby", "apply")
        assert backup_dir is not None
        module.verify_backup(
            backup_dir,
            json.loads((backup_dir / "backup-originals.json").read_text(encoding="ascii"))["records"],
            "backup",
        )
        terminal = json.loads((backup_dir / "transaction-terminal.json").read_text(encoding="ascii"))
        assert terminal["status"] == "committed"
        receipt = backup_dir / "standby-first.receipt"
        receipt_document = module.validate_standby_receipt(receipt.read_bytes())
        assert receipt_document["backup_manifest_sha256"] == terminal["manifest_sha256"]
        assert receipt_document["activation_nonce"] == "a" * 64
        assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
        for asset in module.ASSETS["backup"]:
            assert asset.target.read_bytes() == fixture.payloads[asset.source_name][0]
        module.validate_bootstrap_result()
        module.validate_guard_enabled()
        assert module.timer_snapshot() == backup_timer
        operation_identity = (
            fixture.operation_lock.stat().st_dev,
            fixture.operation_lock.stat().st_ino,
        )

        fixture.write_primary_receipt(receipt.read_bytes())
        timer_before = module.timer_snapshot()
        primary_dir = module.deploy("primary", "authority", "apply")
        assert primary_dir is not None
        primary_terminal = json.loads((primary_dir / "transaction-terminal.json").read_text(encoding="ascii"))
        assert primary_terminal["status"] == "committed"
        assert module.timer_snapshot() == timer_before
        assert fixture.sender_staging.is_dir()
        assert stat.S_IMODE(fixture.sender_staging.stat().st_mode) == 0o700
        assert (
            fixture.operation_lock.stat().st_dev,
            fixture.operation_lock.stat().st_ino,
        ) == operation_identity
        for asset in module.ASSETS["primary"]:
            assert asset.target.read_bytes() == fixture.payloads[asset.source_name][0]
        assert any(
            asset.source_name == "verify-webroot-security"
            for asset in module.ASSETS["primary"]
        )

        calls = fixture.command_log.read_text(encoding="utf-8").splitlines()
        assert "daemon-reload" in calls
        assert "is-enabled shuzijun-sync.timer" in calls
        assert "is-active shuzijun-sync.timer" in calls
        assert "enable shuzijun-sync-fpm-guard.service" in calls
        assert not any(
            line.startswith(("start ", "disable ", "restart "))
            or line == "enable shuzijun-sync.timer"
            for line in calls
        )


def test_backup_manifest_node_is_strict() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-node-manifest-") as temporary:
        fixture = Fixture(temporary, module)
        backup_dir, records = module.create_backup("backup")
        manifest = backup_dir / "backup-originals.json"
        document = json.loads(manifest.read_text(encoding="ascii"))
        document["node"] = "primary"
        manifest.write_bytes(module.canonical_json(document))
        manifest.chmod(0o600)
        expect_failure(
            lambda: module.verify_backup(backup_dir, records, "backup"),
            "manifest mismatch",
        )


def test_atomic_replace_failure_restores_present_and_absent_targets() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-rollback-") as temporary:
        fixture = Fixture(temporary, module)
        absent_target = fixture.targets["shuzijun-sync-transport.sudoers"]
        absent_target.unlink()
        before = fixture.original_target_snapshot("backup")
        original_replace = module.atomic_replace_from_input
        count = 0

        def fail_after_second(asset, stage):
            nonlocal count
            original_replace(asset, stage)
            count += 1
            if count == 2:
                raise module.DeploymentError("injected replace failure")

        module.atomic_replace_from_input = fail_after_second
        expect_failure(lambda: module.deploy("backup", "standby", "apply"), "rolled back")
        operation_identity = (
            fixture.operation_lock.stat().st_dev,
            fixture.operation_lock.stat().st_ino,
        )
        assert fixture.original_target_snapshot("backup") == before
        assert not absent_target.exists()
        assert fixture.operation_lock.read_bytes() == b""
        assert (
            fixture.operation_lock.stat().st_dev,
            fixture.operation_lock.stat().st_ino,
        ) == operation_identity
        terminals = list(fixture.backup_root.glob("*/transaction-terminal.json"))
        assert len(terminals) == 1
        assert json.loads(terminals[0].read_text(encoding="ascii"))["status"] == "rolled-back"


def test_partial_bootstrap_failure_rolls_back_all_created_state() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-bootstrap-rollback-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.accepted.unlink()
        before = fixture.original_target_snapshot("backup")
        original_run = module.run_command

        def fail_bootstrap(argv, *, accepted=None):
            if argv == [str(module.ASSETS["backup"][3].target), "--bootstrap-state", "6"]:
                module.UPLOADS_RELEASE_ROOT.mkdir(mode=0o700)
                write_file(module.ACTIVE_UPLOADS_GENERATION, b"6\n", 0o600)
                write_file(module.FPM_GUARD_LEASE, b"", 0o600)
                raise module.DeploymentError("injected bootstrap failure")
            return original_run(argv, accepted=accepted)

        module.run_command = fail_bootstrap
        expect_failure(lambda: module.deploy("backup", "standby", "apply"), "rolled back")
        assert fixture.original_target_snapshot("backup") == before
        for path in (
            module.ACCEPTED_GENERATION,
            module.UPLOADS_RELEASE_ROOT,
            module.ACTIVE_UPLOADS_GENERATION,
            module.UPLOADS_TRANSACTION,
            module.FPM_GUARD_LEASE,
            module.FPM_GUARD_ARMED,
            module.FPM_GUARD_COMMIT,
            module.ACTIVE_RELEASE_RECORD,
        ):
            assert module.lstat_or_none(path) is None
        terminals = list(fixture.backup_root.glob("*/transaction-terminal.json"))
        assert len(terminals) == 1
        assert json.loads(terminals[0].read_text(encoding="ascii"))["status"] == "rolled-back"


def test_complete_bootstrap_prefix_then_error_rolls_back_exact_state() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-complete-bootstrap-error-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        fixture.accepted.unlink()
        before = fixture.original_target_snapshot("backup")
        original_run = module.run_command

        def fail_after_complete_bootstrap(argv, *, accepted=None):
            result = original_run(argv, accepted=accepted)
            receiver = module.asset_named("backup", "apply-shuzijun-sync").target
            if argv == [str(receiver), "--bootstrap-state", "6"]:
                raise module.DeploymentError("injected error after complete bootstrap")
            return result

        module.run_command = fail_after_complete_bootstrap
        expect_failure(
            lambda: module.deploy("backup", "standby", "apply"), "rolled back"
        )
        assert fixture.original_target_snapshot("backup") == before
        for path in (
            module.ACCEPTED_GENERATION,
            module.UPLOADS_RELEASE_ROOT,
            module.ACTIVE_UPLOADS_GENERATION,
            module.FPM_GUARD_LEASE,
            module.FPM_GUARD_COMMIT,
            module.ACTIVE_RELEASE_RECORD,
        ):
            assert module.lstat_or_none(path) is None


def test_unknown_concurrent_postimage_is_never_overwritten() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-concurrent-image-") as temporary:
        fixture = Fixture(temporary, module)
        originals = {
            str(asset.target): asset.target.read_bytes()
            for asset in module.ASSETS["backup"]
        }
        original_replace = module.atomic_replace_from_input
        count = 0

        def tamper_then_fail(asset, stage):
            nonlocal count
            original_replace(asset, stage)
            count += 1
            if count == 2:
                first = module.ASSETS["backup"][0]
                write_file(first.target, b"unknown-concurrent-image\n", first.mode)
                raise module.DeploymentError("injected concurrent image")

        module.atomic_replace_from_input = tamper_then_fail
        expect_failure(lambda: module.deploy("backup", "standby", "apply"), "unknown concurrent")
        assert module.ASSETS["backup"][0].target.read_bytes() == b"unknown-concurrent-image\n"
        assert module.ASSETS["backup"][1].target.read_bytes() == fixture.payloads[
            module.ASSETS["backup"][1].source_name
        ][0]
        assert module.ASSETS["backup"][2].target.read_bytes() == originals[
            str(module.ASSETS["backup"][2].target)
        ]
        terminal = next(fixture.backup_root.glob("*/transaction-terminal.json"))
        assert json.loads(terminal.read_text(encoding="ascii"))["status"] == "rollback-failed"

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-concurrent-child-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        original_replace = module.atomic_replace_from_input
        count = 0

        def add_unknown_child_then_fail(asset, stage):
            nonlocal count
            original_replace(asset, stage)
            count += 1
            if count == 2:
                write_file(fixture.state / "operator-unknown", b"preserve\n", 0o600)
                raise module.DeploymentError("injected concurrent child")

        module.atomic_replace_from_input = add_unknown_child_then_fail
        expect_failure(
            lambda: module.deploy("backup", "standby", "apply"),
            "unknown",
        )
        assert (fixture.state / "operator-unknown").read_bytes() == b"preserve\n"
        terminal = next(fixture.backup_root.glob("*/transaction-terminal.json"))
        assert json.loads(terminal.read_text(encoding="ascii"))["status"] == "rollback-failed"


def test_operation_lock_loss_blocks_live_rollback_writes() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-lock-loss-") as temporary:
        fixture = Fixture(temporary, module)
        old_receiver = fixture.targets["apply-shuzijun-sync"].read_bytes()
        original_run = module.run_command
        competing_descriptor = None

        def lose_lock_during_bootstrap(argv, *, accepted=None):
            nonlocal competing_descriptor
            receiver = module.asset_named("backup", "apply-shuzijun-sync").target
            if argv == [str(receiver), "--bootstrap-state", "6"]:
                competing_descriptor = os.open(fixture.operation_lock, os.O_RDONLY)
                fcntl.flock(competing_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                raise module.DeploymentError("injected bootstrap lock takeover")
            return original_run(argv, accepted=accepted)

        module.run_command = lose_lock_during_bootstrap
        try:
            expect_failure(lambda: module.deploy("backup", "standby", "apply"))
            # No rollback write is permitted without the site lock: installed
            # candidate bytes remain for explicit operator recovery.
            assert fixture.targets["apply-shuzijun-sync"].read_bytes() != old_receiver
            terminal = next(fixture.backup_root.glob("*/transaction-terminal.json"))
            assert json.loads(terminal.read_text(encoding="ascii"))["status"] == "rollback-failed"
        finally:
            if competing_descriptor is not None:
                os.close(competing_descriptor)


def test_receipt_failure_rolls_back_but_durable_commit_never_does() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-receipt-failure-") as temporary:
        fixture = Fixture(temporary, module)
        before = fixture.original_target_snapshot("backup")
        original_atomic = module.atomic_write_bytes

        def fail_after_receipt_publish(path, payload, mode, *, replace=True):
            original_atomic(path, payload, mode, replace=replace)
            if path.name == "standby-first.receipt":
                raise module.DeploymentError("injected receipt durability failure")

        module.atomic_write_bytes = fail_after_receipt_publish
        expect_failure(lambda: module.deploy("backup", "standby", "apply"), "rolled back")
        assert fixture.original_target_snapshot("backup") == before
        transaction = next(fixture.backup_root.iterdir())
        assert not (transaction / "standby-first.receipt").exists()
        assert json.loads((transaction / "transaction-terminal.json").read_text(encoding="ascii"))["status"] == "rolled-back"

    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-terminal-boundary-") as temporary:
        fixture = Fixture(temporary, module)
        old_receiver = fixture.targets["apply-shuzijun-sync"].read_bytes()
        original_atomic = module.atomic_write_bytes

        def report_error_after_commit_publish(path, payload, mode, *, replace=True):
            original_atomic(path, payload, mode, replace=replace)
            if path.name == "transaction-terminal.json" and b'"status":"committed"' in payload:
                raise module.DeploymentError("injected post-publish report error")

        module.atomic_write_bytes = report_error_after_commit_publish
        backup_dir = module.deploy("backup", "standby", "apply")
        assert backup_dir is not None
        assert fixture.targets["apply-shuzijun-sync"].read_bytes() != old_receiver
        assert json.loads((backup_dir / "transaction-terminal.json").read_text(encoding="ascii"))["status"] == "committed"


def test_operation_lock_foundation_and_metadata_are_fail_closed() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-foundation-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.accepted.unlink()
        fixture.state.rmdir()
        fixture.incoming.rmdir()
        fixture.highest_issued.unlink(missing_ok=True)
        fixture.sync_root.rmdir()

        before = tree_snapshot(fixture.root)
        assert module.deploy("backup", "standby", "dry-run") is None
        assert tree_snapshot(fixture.root) == before
        assert not fixture.sync_root.exists()

        backup_dir = module.deploy("backup", "standby", "apply")
        assert backup_dir is not None
        metadata = fixture.operation_lock.lstat()
        assert stat.S_ISREG(metadata.st_mode)
        assert stat.S_IMODE(metadata.st_mode) == 0o600
        assert metadata.st_nlink == 1
        assert metadata.st_size == 0

    for attack in ("symlink", "hardlink", "nonempty", "fifo", "contention"):
        module = load_deployer()
        with tempfile.TemporaryDirectory(
            prefix=f"sync-release-operation-lock-{attack}-"
        ) as temporary:
            fixture = Fixture(temporary, module)
            held_descriptor = None
            linked = None
            if attack == "symlink":
                linked = fixture.external / "lock-target"
                write_file(linked, b"", 0o600)
                fixture.operation_lock.symlink_to(linked)
            elif attack == "fifo":
                os.mkfifo(fixture.operation_lock, 0o600)
            else:
                write_file(fixture.operation_lock, b"", 0o600)
                if attack == "hardlink":
                    linked = fixture.external / "lock-hardlink"
                    os.link(fixture.operation_lock, linked)
                elif attack == "nonempty":
                    fixture.operation_lock.write_bytes(b"not-empty\n")
                else:
                    held_descriptor = os.open(fixture.operation_lock, os.O_RDONLY)
                    fcntl.flock(held_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                expect_failure(lambda: module.deploy("backup", "standby", "dry-run"))
                assert not fixture.backup_root.exists()
            finally:
                if held_descriptor is not None:
                    os.close(held_descriptor)
                if linked is not None and attack == "hardlink":
                    linked.unlink()


def test_fresh_guard_not_found_transition_and_exact_rollback() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-fresh-guard-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.targets["shuzijun-sync-fpm-guard.service"].unlink()
        before = module.runtime_snapshot("backup")
        assert module.classify_inactive_unit(
            before["units"][module.FPM_GUARD_SERVICE], module.FPM_GUARD_SERVICE
        ) == "not-found"
        backup_dir = module.deploy("backup", "standby", "apply")
        assert backup_dir is not None
        module.validate_guard_enabled()

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-fresh-guard-rollback-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        fixture.targets["shuzijun-sync-fpm-guard.service"].unlink()
        before = module.runtime_snapshot("backup")
        original_atomic = module.atomic_write_bytes

        def fail_after_receipt(path, payload, mode, *, replace=True):
            original_atomic(path, payload, mode, replace=replace)
            if path.name == "standby-first.receipt":
                raise module.DeploymentError("injected fresh guard rollback")

        module.atomic_write_bytes = fail_after_receipt
        expect_failure(
            lambda: module.deploy("backup", "standby", "apply"), "rolled back"
        )
        after = module.runtime_snapshot("backup")
        assert after == before
        assert module.classify_inactive_unit(
            after["units"][module.FPM_GUARD_SERVICE], module.FPM_GUARD_SERVICE
        ) == "not-found"
        assert not module.GUARD_ENABLEMENT_LINK.exists()
        assert not fixture.targets["shuzijun-sync-fpm-guard.service"].exists()


def test_primary_post_install_health_gate_is_repeated() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-primary-post-gate-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.write_primary_receipt()
        before = fixture.original_target_snapshot("primary")
        original_gate = module.require_primary_recovery_clear
        calls = 0

        def fail_only_post_install_gate():
            nonlocal calls
            calls += 1
            if calls == 3:
                raise module.DeploymentError("injected post-install health gate")
            return original_gate()

        module.require_primary_recovery_clear = fail_only_post_install_gate
        expect_failure(
            lambda: module.deploy("primary", "authority", "apply"), "rolled back"
        )
        assert calls >= 4
        assert fixture.original_target_snapshot("primary") == before

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-primary-marker-after-install-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        fixture.write_primary_receipt()
        original_gate = module.require_primary_recovery_clear
        calls = 0

        def introduce_marker_at_post_gate():
            nonlocal calls
            calls += 1
            if calls == 3:
                module.PRIMARY_FPM_FREEZE_ROOT.mkdir(mode=0o700, exist_ok=True)
                write_file(module.PRIMARY_FPM_FREEZE_MARKER, b"concurrent\n", 0o600)
            return original_gate()

        module.require_primary_recovery_clear = introduce_marker_at_post_gate
        expect_failure(
            lambda: module.deploy("primary", "authority", "apply"),
            "runtime state changed before rollback",
        )
        terminal = next(fixture.backup_root.glob("*/transaction-terminal.json"))
        assert json.loads(terminal.read_text(encoding="ascii"))["status"] == "rollback-failed"


def test_sigkill_bootstrap_boundaries_resume_on_next_apply() -> None:
    if not hasattr(os, "fork"):
        return
    for boundary in (
        "after-root",
        "before-active",
        "after-active",
        "after-commit",
        "after-active-release",
    ):
        module = load_deployer()
        with tempfile.TemporaryDirectory(
            prefix=f"sync-release-bootstrap-kill-{boundary}-"
        ) as temporary:
            fixture = Fixture(temporary, module)
            fixture.bootstrap_crash.write_text(boundary + "\n", encoding="ascii")
            child = os.fork()
            if child == 0:
                try:
                    module.deploy("backup", "standby", "apply")
                except BaseException:
                    os._exit(91)
                os._exit(0)
            waited, status = os.waitpid(child, 0)
            assert waited == child
            assert os.WIFSIGNALED(status), (boundary, status)
            assert os.WTERMSIG(status) == signal.SIGKILL, (boundary, status)
            # The fixture receiver exits immediately after signaling its
            # deployer parent; allow that orphan to close its descriptors.
            time.sleep(0.2)
            fixture.bootstrap_crash.write_text("", encoding="ascii")

            backup_dir = module.deploy("backup", "standby", "apply")
            assert backup_dir is not None
            state = module.validate_bootstrap_result()
            assert state.activation_nonce == "a" * 64
            assert module.validate_standby_receipt(
                (backup_dir / "standby-first.receipt").read_bytes()
            )["release_id"] == state.release_id


def test_receiver_state_inventory_and_stale_temp_rollback() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-state-temp-") as temporary:
        fixture = Fixture(temporary, module)
        stale = fixture.state / (".active-release-v4." + "1" * 32)
        retained = fixture.state / (".fpm-guard-marker." + "2" * 32)
        write_file(stale, b'{"partial":true}\n', 0o600)
        write_file(retained, b"partial\n", 0o600)
        assert module.validate_receiver_state_inventory() == (stale,)
        backup_dir = module.deploy("backup", "standby", "apply")
        assert backup_dir is not None
        assert not stale.exists()
        assert retained.read_bytes() == b"partial\n"

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-state-temp-rollback-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        stale = fixture.state / (".bootstrap-fpm-commit." + "3" * 32)
        write_file(stale, b"partial-commit\n", 0o600)
        original_atomic = module.atomic_write_bytes

        def fail_after_receipt(path, payload, mode, *, replace=True):
            original_atomic(path, payload, mode, replace=replace)
            if path.name == "standby-first.receipt":
                raise module.DeploymentError("injected stale-temp rollback")

        module.atomic_write_bytes = fail_after_receipt
        expect_failure(
            lambda: module.deploy("backup", "standby", "apply"), "rolled back"
        )
        assert stale.read_bytes() == b"partial-commit\n"
        assert stat.S_IMODE(stale.stat().st_mode) == 0o600

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-state-temp-invalid-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        unknown = fixture.state / (".active-release-v4." + "x" * 32)
        write_file(unknown, b"", 0o600)
        expect_failure(
            lambda: module.deploy("backup", "standby", "dry-run"),
            "unknown receiver state inventory",
        )
        assert not fixture.backup_root.exists()

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-rollback-temp-oversized-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        rollback = fixture.state / ".rollback-database.123"
        with rollback.open("wb") as stream:
            stream.truncate(4 * 1024 * 1024 * 1024 + 1)
        rollback.chmod(0o600)
        expect_failure(
            lambda: module.deploy("backup", "standby", "dry-run"),
            "oversized rollback database temporary",
        )
        assert not fixture.backup_root.exists()


def test_primary_generation_temp_inventory_is_exact_and_not_deleted() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(prefix="sync-release-primary-temp-") as temporary:
        fixture = Fixture(temporary, module)
        fixture.write_primary_receipt()
        stale = fixture.sync_root / (".highest-issued." + "4" * 32)
        write_file(stale, b"7\n", 0o600)
        assert module.deploy("primary", "authority", "dry-run") is None
        assert stale.read_bytes() == b"7\n"
        primary_dir = module.deploy("primary", "authority", "apply")
        assert primary_dir is not None
        assert stale.read_bytes() == b"7\n"

    for suffix, payload in (("x" * 32, b""), ("5" * 32, b"0\n")):
        module = load_deployer()
        with tempfile.TemporaryDirectory(
            prefix="sync-release-primary-temp-invalid-"
        ) as temporary:
            fixture = Fixture(temporary, module)
            fixture.write_primary_receipt()
            path = fixture.sync_root / (".highest-issued." + suffix)
            write_file(path, payload, 0o600)
            expect_failure(
                lambda: module.deploy("primary", "authority", "dry-run"),
                "highest-issued",
            )
            assert not fixture.backup_root.exists()

    for state in ("missing", "wrong-generation", "hardlink", "fifo"):
        module = load_deployer()
        with tempfile.TemporaryDirectory(
            prefix=f"sync-release-primary-generation-{state}-"
        ) as temporary:
            fixture = Fixture(temporary, module)
            fixture.write_primary_receipt()
            if state == "missing":
                fixture.highest_issued.unlink()
            elif state == "wrong-generation":
                fixture.highest_issued.write_bytes(b"7\n")
            else:
                if state == "hardlink":
                    linked = fixture.external / "highest-issued-generation.link"
                    os.link(fixture.highest_issued, linked)
                else:
                    fixture.highest_issued.unlink()
                    os.mkfifo(fixture.highest_issued, 0o600)
            expect_failure(
                lambda: module.deploy("primary", "authority", "dry-run"),
                "highest-issued-generation"
                if state in {"missing", "wrong-generation"}
                else "unsafe regular file metadata",
            )
            assert not fixture.backup_root.exists()
            assert not fixture.sender_staging.exists()


def test_node_specific_runtime_inventory_is_exact() -> None:
    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-standby-inventory-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        claim = fixture.incoming / "batch.Recoverable123"
        claim.mkdir(mode=0o700)
        write_file(claim / "control", b"partial\n", 0o600)
        before = tree_snapshot(fixture.root)
        assert module.deploy("backup", "standby", "dry-run") is None
        assert tree_snapshot(fixture.root) == before

        foreign = fixture.sync_root / "sender-staging"
        foreign.mkdir(mode=0o700)
        expect_failure(
            lambda: module.deploy("backup", "standby", "dry-run"),
            "unknown standby sync-root inventory",
        )
        assert not fixture.backup_root.exists()

    module = load_deployer()
    with tempfile.TemporaryDirectory(
        prefix="sync-release-primary-inventory-"
    ) as temporary:
        fixture = Fixture(temporary, module)
        fixture.write_primary_receipt()
        fixture.sender_staging.mkdir(mode=0o700)
        token = "7" * 32
        batch = fixture.sender_staging / f"batch.{token}"
        batch.mkdir(mode=0o700)
        write_file(
            batch / ".sender-staging-owner.json",
            module.canonical_json({"token": token, "version": 1}),
            0o600,
        )
        payload = batch / "payload"
        payload.mkdir(mode=0o700)
        write_file(payload / "part", b"partial\n", 0o600)
        assert module.deploy("primary", "authority", "dry-run") is None

        write_file(batch / ".sender-staging-owner.json", b'{"token":', 0o600)
        expect_failure(
            lambda: module.deploy("primary", "authority", "dry-run"),
            "sender staging owner is invalid",
        )
        assert not fixture.backup_root.exists()


def main() -> None:
    test_static_fail_closed_contract()
    test_metadata_symlink_hardlink_and_allowlists()
    test_dry_run_is_read_only_and_timer_gate_is_dynamic()
    test_primary_stale_recovery_and_runtime_health_are_hard_gates()
    test_external_commands_have_a_real_timeout()
    test_standby_first_commit_then_primary_and_integrity()
    test_backup_manifest_node_is_strict()
    test_atomic_replace_failure_restores_present_and_absent_targets()
    test_partial_bootstrap_failure_rolls_back_all_created_state()
    test_complete_bootstrap_prefix_then_error_rolls_back_exact_state()
    test_unknown_concurrent_postimage_is_never_overwritten()
    test_operation_lock_loss_blocks_live_rollback_writes()
    test_receipt_failure_rolls_back_but_durable_commit_never_does()
    test_operation_lock_foundation_and_metadata_are_fail_closed()
    test_fresh_guard_not_found_transition_and_exact_rollback()
    test_primary_post_install_health_gate_is_repeated()
    test_sigkill_bootstrap_boundaries_resume_on_next_apply()
    test_receiver_state_inventory_and_stale_temp_rollback()
    test_primary_generation_temp_inventory_is_exact_and_not_deleted()
    test_node_specific_runtime_inventory_is_exact()
    print("sync-release-deployer-contract-test: passed")


if __name__ == "__main__":
    main()
