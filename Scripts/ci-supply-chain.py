#!/usr/bin/env python3
"""Fail-closed CI provenance, dependency-lock, and SBOM utilities."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-quality.yml"
RUNNER_POLICY = ROOT / ".github/runner-policy.json"
RUNTIME_INPUT = ROOT / "Server/entitlement-verifier/requirements.in"
RUNTIME_REQUIREMENTS = ROOT / "Server/entitlement-verifier/requirements.txt"
QUALITY_INPUT = ROOT / ".github/requirements-quality.in"
QUALITY_LOCK = ROOT / ".github/requirements-quality.txt"
COMPOSER_MANIFEST = ROOT / "Server/composer.json"
COMPOSER_LOCK = ROOT / "Server/composer.lock"
XCODE_PROJECT = ROOT / "Yishu.xcodeproj/project.pbxproj"
SECURITY_CHECK = ROOT / "Scripts/security-check.sh"
RELEASE_ANALYZE = ROOT / "Scripts/ci-release-analyze.sh"
PROVENANCE_MATERIALS = (
    ROOT / ".github/dependabot.yml",
    WORKFLOW,
    RUNNER_POLICY,
    QUALITY_INPUT,
    QUALITY_LOCK,
    RUNTIME_INPUT,
    RUNTIME_REQUIREMENTS,
    ROOT / "Server/ruff.toml",
    Path(__file__).resolve(),
    ROOT / "Server/tests/ci-supply-chain-contract-test.py",
    SECURITY_CHECK,
    COMPOSER_MANIFEST,
    COMPOSER_LOCK,
    XCODE_PROJECT,
    RELEASE_ANALYZE,
)

PIN_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9_.-]+(?:\[[A-Za-z0-9_,.-]+\])?)"
    r"==(?P<version>[A-Za-z0-9_.+!-]+)(?:\s+\\)?$"
)
HASH_RE = re.compile(r"^--hash=sha256:[0-9a-f]{64}(?:\s+\\)?$")
ACTION_RE = re.compile(
    r"^\s*(?:-\s*)?uses:\s*(?P<quote>['\"]?)(?P<reference>[^\s#'\"]+)(?P=quote)"
    r"(?:\s+#.*)?$",
    re.MULTILINE,
)
USES_LINE_RE = re.compile(r"^\s*(?:-\s*)?uses\s*:", re.MULTILINE)
REMOTE_ACTION_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# GitHub-hosted runner image revisions are emitted in either date.sequence or
# date.build.sequence form. Keep the accepted grammar narrow while supporting
# both documented canonical layouts.
IMAGE_VERSION_RE = re.compile(r"^[0-9]{8}(?:\.[0-9]+){1,2}$")
EXPECTED_ACTION_PINS = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",
    "actions/setup-python": "e797f83bcb11b83ae66e0230d6156d7c80228e7c",
    "actions/upload-artifact": "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "shivammathur/setup-php": "f3e473d116dcccaddc5834248c87452386958240",
}


class PolicyError(RuntimeError):
    """A supply-chain policy invariant did not hold."""


@dataclass
class Requirement:
    name: str
    version: str
    hashes: set[str] = field(default_factory=set)

    @property
    def normalized_name(self) -> str:
        return re.sub(r"[-_.]+", "-", self.name.split("[", 1)[0]).lower()


@dataclass(frozen=True)
class Component:
    ecosystem: str
    name: str
    version: str
    scope: str
    source: str

    @property
    def purl(self) -> str:
        escaped_name = quote(self.name, safe="/.-_")
        return f"pkg:{self.ecosystem}/{escaped_name}@{quote(self.version, safe='.-_+')}"

    @property
    def bom_ref(self) -> str:
        return self.purl


def fail(message: str) -> None:
    raise PolicyError(message)


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyError(f"cannot read canonical JSON {path}: {error}") from error
    if not isinstance(value, dict):
        fail(f"expected JSON object: {path}")
    return value


def parse_requirements(path: Path, *, hashes_required: bool) -> dict[str, Requirement]:
    requirements: dict[str, Requirement] = {}
    active: Requirement | None = None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise PolicyError(f"cannot read requirements file {path}: {error}") from error

    for line_number, raw_line in enumerate(lines, 1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = PIN_RE.fullmatch(stripped)
        if match:
            active = Requirement(match.group("name"), match.group("version"))
            key = active.normalized_name
            if key in requirements:
                fail(f"duplicate requirement {active.name} in {path}:{line_number}")
            requirements[key] = active
            continue
        if HASH_RE.fullmatch(stripped):
            if active is None:
                fail(f"orphan requirement hash in {path}:{line_number}")
            active.hashes.add(stripped.rstrip(" \\"))
            continue
        fail(f"non-exact or unsupported requirement in {path}:{line_number}")

    if not requirements:
        fail(f"empty requirements file: {path}")
    if hashes_required:
        missing = sorted(item.name for item in requirements.values() if not item.hashes)
        if missing:
            fail(f"requirements without hashes in {path}: {', '.join(missing)}")
    return requirements


def validate_runner_policy() -> dict[str, Any]:
    policy = read_json(RUNNER_POLICY)
    expected = {
        "schema": 1,
        "repository": "Saruika/shuzi",
        "runner_label": "macos-26",
        "runner_environment": "github-hosted",
        "runner_os": "macOS",
        "runner_arch": "ARM64",
        "image_os": "macos26",
        "image_source": "https://github.com/actions/runner-images",
        "image_definition": "images/macos/macos-26-arm64-Readme.md",
        "image_revision_strategy": "record-and-attest-every-run",
        "macos_product_major": 26,
        "developer_dir": "/Applications/Xcode.app/Contents/Developer",
        "xcode_version": "26.6",
        "xcode_build": "17F113",
        "python_version": "3.12.14",
        "php_version_line": "8.3",
        "php_version_strategy": "minor-line-record-and-attest-every-run",
        "composer_version": "2.9.8",
    }
    if policy != expected:
        fail("runner policy differs from the reviewed macos-26/Xcode/Python contract")
    return policy


def validate_actions(workflow_path: Path = WORKFLOW) -> list[tuple[str, str]]:
    text = workflow_path.read_text(encoding="utf-8")
    matches = list(ACTION_RE.finditer(text))
    if len(matches) != len(USES_LINE_RE.findall(text)):
        fail("workflow contains a malformed or unsupported action reference")
    actions: list[tuple[str, str]] = []
    seen_actions: set[str] = set()
    for match in matches:
        reference = match.group("reference")
        if reference.startswith("./") or reference.startswith("docker://"):
            fail(f"unreviewed local/container action reference: {reference}")
        if not REMOTE_ACTION_RE.fullmatch(reference):
            fail(f"GitHub action is not pinned to a 40-character commit: {reference}")
        action, commit = reference.rsplit("@", 1)
        expected_commit = EXPECTED_ACTION_PINS.get(action)
        if expected_commit is None or commit != expected_commit:
            fail(f"GitHub action is outside the reviewed action allowlist: {reference}")
        actions.append((action, commit))
        seen_actions.add(action)
    if not actions:
        fail("workflow contains no pinned actions")
    missing_actions = sorted(set(EXPECTED_ACTION_PINS) - seen_actions)
    if missing_actions:
        fail(f"workflow is missing reviewed actions: {', '.join(missing_actions)}")
    return actions


def validate_composer() -> list[Component]:
    manifest = read_json(COMPOSER_MANIFEST)
    lock = read_json(COMPOSER_LOCK)
    required = manifest.get("require")
    if not isinstance(required, dict):
        fail("composer require section is missing")
    for name, version in required.items():
        if name == "php":
            continue
        if not isinstance(version, str) or not re.fullmatch(r"v?[0-9]+(?:\.[0-9]+){2}", version):
            fail(f"Composer dependency is not exact: {name}={version!r}")

    packages = lock.get("packages")
    if not isinstance(packages, list):
        fail("composer.lock packages section is missing")
    components: list[Component] = []
    locked: dict[str, str] = {}
    for package in packages:
        if not isinstance(package, dict):
            fail("invalid Composer package record")
        name = package.get("name")
        version = package.get("version")
        source = package.get("source")
        if not isinstance(name, str) or not isinstance(version, str) or not isinstance(source, dict):
            fail("incomplete Composer package record")
        reference = source.get("reference")
        if not isinstance(reference, str) or not SHA_RE.fullmatch(reference):
            fail(f"Composer source is not pinned to a commit: {name}")
        locked[name] = version.lstrip("v")
        components.append(Component("composer", name, version.lstrip("v"), "required", "composer.lock"))

    for name, expected_version in required.items():
        if name == "php":
            continue
        if locked.get(name) != expected_version.lstrip("v"):
            fail(f"composer.json/composer.lock mismatch for {name}")
    return components


def validate_xcode_dependencies() -> None:
    text = XCODE_PROJECT.read_text(encoding="utf-8")
    if "XCRemoteSwiftPackageReference" not in text:
        return
    if "branch =" in text or "upToNextMajorVersion" in text or "upToNextMinorVersion" in text:
        fail("Swift package dependencies must not use branches or moving semantic ranges")
    references = re.findall(r"revision\s*=\s*([0-9a-f]+);", text)
    if not references or any(not SHA_RE.fullmatch(reference) for reference in references):
        fail("every Swift package dependency must use an exact 40-character revision")


def validate_workflow_contract() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    required_fragments = (
        "runs-on: macos-26",
        "DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer",
        "CI_PYTHON_VERSION: '3.12.14'",
        "CI_PHP_VERSION: '8.3'",
        "CI_COMPOSER_VERSION: '2.9.8'",
        "actions/setup-python@e797f83bcb11b83ae66e0230d6156d7c80228e7c",
        "python-version: ${{ env.CI_PYTHON_VERSION }}",
        "php-version: ${{ env.CI_PHP_VERSION }}",
        "tools: composer:${{ env.CI_COMPOSER_VERSION }}",
        "--require-hashes",
        "Scripts/ci-supply-chain.py provenance",
        "Scripts/ci-supply-chain.py validate",
        "Scripts/ci-supply-chain.py sbom",
        "-m ruff check",
        "Run Python SAST with Bandit",
        "-m bandit",
        "--severity-level medium",
        "--confidence-level medium",
        "--exclude Server/tests,Server/vendor",
        "Server/operations \\",
        "Run Swift compiler analysis and audit Release bundle",
        "-m pip_audit",
        "Scripts/ci-supply-chain.py verify-audit",
        "--requirement Server/entitlement-verifier/requirements.txt",
        "--requirement .github/requirements-quality.txt",
        "--format cyclonedx-json",
        "python-runtime-audit.cdx.json",
        "python-quality-audit.cdx.json",
        "Audit Composer dependency components",
        "composer audit --locked --working-dir=Server",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "retention-days: 30",
    )
    for fragment in required_fragments:
        if fragment not in text:
            fail(f"workflow is missing supply-chain contract: {fragment}")
    if text.count("\n            --disable-pip \\\n") != 2:
        fail("both pip-audit invocations must disable ambient pip state")
    if text.count("Scripts/ci-supply-chain.py verify-audit") != 2:
        fail("both Python audits must prove complete lock coverage")
    if text.count("\npermissions:\n  contents: read\n") != 1 or (
        "\n    permissions:\n" in text
    ):
        fail("quality workflow permission maps differ from the reviewed read-only contract")
    if "write-all" in text or re.search(r"^\s+[A-Za-z-]+:\s+write\s*$", text, re.MULTILINE):
        fail("quality workflow requests unnecessary write permissions")
    security_check = SECURITY_CHECK.read_text(encoding="utf-8")
    if "composer audit --locked --no-dev --working-dir=Server" not in security_check:
        fail("security check no longer performs the locked Composer vulnerability audit")
    release_analyze = RELEASE_ANALYZE.read_text(encoding="utf-8")
    if "xcodebuild \\" not in release_analyze or re.search(
        r"^\s*analyze\s*$", release_analyze, re.MULTILINE
    ) is None:
        fail("Swift compiler analysis is no longer enforced")
    if (
        "GCC_TREAT_WARNINGS_AS_ERRORS=YES" not in release_analyze
        or "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" not in release_analyze
    ):
        fail("Swift compiler diagnostics are not configured as build-blocking findings")


def validate() -> dict[str, int]:
    validate_runner_policy()
    runtime_input = parse_requirements(RUNTIME_INPUT, hashes_required=False)
    if set(runtime_input) != {"app-store-server-library", "fastapi", "uvicorn"}:
        fail("entitlement verifier direct runtime dependency set changed without review")
    runtime = parse_requirements(RUNTIME_REQUIREMENTS, hashes_required=True)
    for name, direct in runtime_input.items():
        locked = runtime.get(name)
        if locked is None or locked.version != direct.version:
            fail(f"runtime input/lock mismatch for {name}")
    quality_input = parse_requirements(QUALITY_INPUT, hashes_required=False)
    if set(quality_input) != {"bandit", "jsonschema", "pip-audit", "ruff"}:
        fail("CI quality dependency set changed without review")
    quality_lock = parse_requirements(QUALITY_LOCK, hashes_required=True)
    for name, direct in quality_input.items():
        locked = quality_lock.get(name)
        if locked is None or locked.version != direct.version:
            fail(f"quality input/lock mismatch for {name}")
    actions = validate_actions()
    validate_workflow_contract()
    composer = validate_composer()
    validate_xcode_dependencies()
    result = {
        "runtime_python_direct": len(runtime_input),
        "runtime_python_locked": len(runtime),
        "quality_python_locked": len(quality_lock),
        "composer_locked": len(composer),
        "github_actions_locked": len(actions),
    }
    print("supply-chain-policy: passed " + " ".join(f"{key}={value}" for key, value in result.items()))
    return result


def command_output(command: list[str]) -> str:
    try:
        return subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise PolicyError(f"cannot collect provenance from {command[0]}: {error}") from error


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def provenance(output: Path) -> None:
    policy = validate_runner_policy()
    expected_environment = {
        "GITHUB_ACTIONS": "true",
        "GITHUB_REPOSITORY": policy["repository"],
        "CI_RUNNER_LABEL": policy["runner_label"],
        "CI_RUNNER_ENVIRONMENT": policy["runner_environment"],
        "CI_PHP_VERSION": policy["php_version_line"],
        "CI_COMPOSER_VERSION": policy["composer_version"],
        "RUNNER_OS": policy["runner_os"],
        "RUNNER_ARCH": policy["runner_arch"],
        "ImageOS": policy["image_os"],
        "DEVELOPER_DIR": policy["developer_dir"],
    }
    for key, expected in expected_environment.items():
        if os.environ.get(key) != expected:
            fail(f"runner provenance mismatch: {key}")

    image_version = os.environ.get("ImageVersion", "")
    if not IMAGE_VERSION_RE.fullmatch(image_version):
        fail("GitHub runner ImageVersion is missing or non-canonical")
    commit = os.environ.get("GITHUB_SHA", "")
    if not SHA_RE.fullmatch(commit):
        fail("GITHUB_SHA is missing or non-canonical")

    product_version = command_output(["/usr/bin/sw_vers", "-productVersion"])
    product_build = command_output(["/usr/bin/sw_vers", "-buildVersion"])
    if product_version.split(".", 1)[0] != str(policy["macos_product_major"]):
        fail("macOS runner major version differs from policy")

    xcode_lines = command_output(["/usr/bin/xcodebuild", "-version"]).splitlines()
    if xcode_lines != [f"Xcode {policy['xcode_version']}", f"Build version {policy['xcode_build']}"]:
        fail("Xcode toolchain differs from policy")
    if platform.python_version() != policy["python_version"]:
        fail("Python interpreter differs from policy")
    if platform.machine().lower() != "arm64":
        fail("runner machine architecture differs from policy")

    python_path = Path(sys.executable).resolve(strict=True)
    developer_root = Path(policy["developer_dir"]).resolve(strict=True)
    xcodebuild_path = Path(
        command_output(["/usr/bin/xcrun", "--find", "xcodebuild"])
    ).resolve(strict=True)
    try:
        xcodebuild_path.relative_to(developer_root)
    except ValueError as error:
        raise PolicyError("xcodebuild resolved outside the pinned developer directory") from error

    php_executable = shutil.which("php")
    composer_executable = shutil.which("composer")
    if php_executable is None or composer_executable is None:
        fail("PHP or Composer is unavailable after the pinned setup action")
    php_path = Path(php_executable).resolve(strict=True)
    composer_path = Path(composer_executable).resolve(strict=True)
    php_version = command_output([str(php_path), "-r", "echo PHP_VERSION;"])
    if (
        re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", php_version) is None
        or not php_version.startswith(f"{policy['php_version_line']}.")
    ):
        fail("PHP version differs from the reviewed minor release line")
    composer_output = command_output([str(composer_path), "--no-ansi", "--version"])
    composer_match = re.fullmatch(r"Composer version ([0-9]+(?:\.[0-9]+){2})(?: .*)?", composer_output)
    if composer_match is None or composer_match.group(1) != policy["composer_version"]:
        fail("Composer version differs from the reviewed release")
    composer_version = composer_match.group(1)
    payload: dict[str, Any] = {
        "schema": 1,
        "subject": {"repository": policy["repository"], "commit": commit},
        "runner": {
            "label": policy["runner_label"],
            "environment": policy["runner_environment"],
            "name": os.environ.get("RUNNER_NAME", ""),
            "architecture": os.environ["RUNNER_ARCH"],
            "image_os": os.environ["ImageOS"],
            "image_version": image_version,
            "image_source": policy["image_source"],
            "image_definition": policy["image_definition"],
            "image_revision_strategy": policy["image_revision_strategy"],
            "os_product_version": product_version,
            "os_build": product_build,
        },
        "toolchain": {
            "developer_dir": os.environ["DEVELOPER_DIR"],
            "xcode_version": policy["xcode_version"],
            "xcode_build": policy["xcode_build"],
            "xcodebuild_path": str(xcodebuild_path),
            "xcodebuild_sha256": sha256_file(xcodebuild_path),
            "python_version": platform.python_version(),
            "python_path": str(python_path),
            "python_sha256": sha256_file(python_path),
            "php_version": php_version,
            "php_version_line_policy": policy["php_version_line"],
            "php_version_strategy": policy["php_version_strategy"],
            "php_path": str(php_path),
            "php_sha256": sha256_file(php_path),
            "composer_version": composer_version,
            "composer_version_policy": policy["composer_version"],
            "composer_path": str(composer_path),
            "composer_sha256": sha256_file(composer_path),
            "swift_version": command_output(["/usr/bin/xcrun", "swiftc", "--version"]),
        },
        "github": {
            "workflow_ref": os.environ.get("GITHUB_WORKFLOW_REF", ""),
            "run_id": os.environ.get("GITHUB_RUN_ID", ""),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        },
        "materials": {
            str(path.relative_to(ROOT)): sha256_file(path)
            for path in PROVENANCE_MATERIALS
        },
    }
    atomic_json(output, payload)
    print(f"runner-provenance: passed image={image_version} output={output}")


def requirement_components(path: Path, scope: str, source: str) -> list[Component]:
    return [
        Component("pypi", requirement.normalized_name, requirement.version, scope, source)
        for requirement in parse_requirements(path, hashes_required=True).values()
    ]


def reviewed_requirements_path(path: Path) -> Path:
    candidate = path if path.is_absolute() else ROOT / path
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise PolicyError(f"cannot resolve audited requirements file: {error}") from error
    allowed = {
        RUNTIME_REQUIREMENTS.resolve(strict=True),
        QUALITY_LOCK.resolve(strict=True),
    }
    if resolved not in allowed:
        fail("audit verification accepts only reviewed Python lock files")
    return resolved


def verify_audit(audit_path: Path, requirements_path: Path) -> None:
    reviewed_requirements = reviewed_requirements_path(requirements_path)
    expected_requirements = parse_requirements(reviewed_requirements, hashes_required=True)
    audit = read_json(audit_path)
    if audit.get("bomFormat") != "CycloneDX" or audit.get("specVersion") != "1.4":
        fail("pip-audit output is not the reviewed CycloneDX 1.4 format")
    components = audit.get("components")
    if not isinstance(components, list):
        fail("pip-audit output has no component list")

    actual: dict[str, str] = {}
    for index, component in enumerate(components):
        if not isinstance(component, dict):
            fail(f"pip-audit component {index} is not an object")
        name = component.get("name")
        version = component.get("version")
        if not isinstance(name, str) or not isinstance(version, str):
            fail(f"pip-audit component {index} has no canonical name/version")
        normalized_name = re.sub(r"[-_.]+", "-", name).lower()
        if normalized_name in actual:
            fail(f"pip-audit output contains duplicate component: {normalized_name}")
        actual[normalized_name] = version

    expected = {
        name: requirement.version for name, requirement in expected_requirements.items()
    }
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(
            name for name in set(expected) & set(actual) if expected[name] != actual[name]
        )
        fail(
            "pip-audit component coverage differs from the complete hash lock "
            f"(missing={missing}, extra={extra}, changed={changed})"
        )
    print(
        "pip-audit-coverage: passed "
        f"requirements={reviewed_requirements.relative_to(ROOT)} components={len(actual)}"
    )


def collect_components() -> list[Component]:
    components = requirement_components(
        RUNTIME_REQUIREMENTS, "required", "Server/entitlement-verifier/requirements.txt"
    )
    components.extend(requirement_components(QUALITY_LOCK, "development", ".github/requirements-quality.txt"))
    components.extend(validate_composer())
    for action, commit in validate_actions():
        components.append(Component("github", action, commit, "development", ".github/workflows/ios-quality.yml"))

    unique: dict[tuple[str, str, str], Component] = {}
    for component in components:
        key = (component.ecosystem, component.name.lower(), component.version)
        existing = unique.get(key)
        if existing is None or component.scope == "required":
            unique[key] = component
    return sorted(unique.values(), key=lambda item: (item.ecosystem, item.name.lower(), item.version))


def source_timestamp() -> str:
    source_date_epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if source_date_epoch is not None:
        try:
            instant = dt.datetime.fromtimestamp(int(source_date_epoch), tz=dt.timezone.utc)
        except (ValueError, OSError, OverflowError) as error:
            raise PolicyError("SOURCE_DATE_EPOCH is not a canonical integer timestamp") from error
    else:
        instant = dt.datetime.now(tz=dt.timezone.utc)
    return instant.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def cyclonedx_document(components: list[Component], timestamp: str, commit: str) -> dict[str, Any]:
    serial_seed = "\n".join(component.bom_ref for component in components)
    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"https://github.com/Saruika/shuzi/{commit}/{serial_seed}")
    root_ref = f"pkg:generic/cn.com.shuzijun.yishu@{commit}"
    return {
        "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": {"components": [{"type": "application", "name": "ci-supply-chain.py", "version": "1"}]},
            "component": {
                "type": "application",
                "bom-ref": root_ref,
                "name": "Hi, Shuzi iOS App",
                "version": commit,
            },
        },
        "components": [
            {
                "type": "library",
                "bom-ref": component.bom_ref,
                "name": component.name,
                "version": component.version,
                # CycloneDX only permits required/optional/excluded here. Keep
                # the more precise runtime/development classification as a
                # namespaced property instead of emitting a non-schema value.
                "scope": "required" if component.scope == "required" else "excluded",
                "purl": component.purl,
                "properties": [
                    {"name": "shuzijun:lock-source", "value": component.source},
                    {
                        "name": "shuzijun:dependency-scope",
                        "value": "runtime" if component.scope == "required" else "development",
                    },
                ],
            }
            for component in components
        ],
        "dependencies": [{"ref": root_ref, "dependsOn": [component.bom_ref for component in components]}],
    }


def spdx_identifier(component: Component) -> str:
    normalized = re.sub(r"[^A-Za-z0-9.-]+", "-", f"{component.ecosystem}-{component.name}")
    suffix = hashlib.sha256(component.bom_ref.encode("utf-8")).hexdigest()[:12]
    return f"SPDXRef-{normalized}-{suffix}"


def spdx_document(components: list[Component], timestamp: str, commit: str) -> dict[str, Any]:
    digest = hashlib.sha256("\n".join(component.bom_ref for component in components).encode("utf-8")).hexdigest()
    root_id = "SPDXRef-RootPackage"
    packages: list[dict[str, Any]] = [
        {
            "SPDXID": root_id,
            "name": "Hi, Shuzi iOS App",
            "versionInfo": commit,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        }
    ]
    relationships: list[dict[str, str]] = [
        {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root_id}
    ]
    for component in components:
        identifier = spdx_identifier(component)
        packages.append(
            {
                "SPDXID": identifier,
                "name": component.name,
                "versionInfo": component.version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": component.purl,
                    }
                ],
                "annotations": [
                    {
                        "annotationDate": timestamp,
                        "annotationType": "OTHER",
                        "annotator": "Tool: ci-supply-chain.py-1",
                        "comment": f"lock-source={component.source}; scope={component.scope}",
                    }
                ],
            }
        )
        if component.scope == "required":
            relationships.append(
                {
                    "spdxElementId": root_id,
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": identifier,
                }
            )
        else:
            relationships.append(
                {
                    "spdxElementId": identifier,
                    "relationshipType": "DEV_DEPENDENCY_OF",
                    "relatedSpdxElement": root_id,
                }
            )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Saruika-shuzi-{commit}",
        "documentNamespace": f"https://github.com/Saruika/shuzi/sbom/{commit}/{digest}",
        "creationInfo": {"created": timestamp, "creators": ["Tool: ci-supply-chain.py-1"]},
        "documentDescribes": [root_id],
        "packages": packages,
        "relationships": relationships,
    }


def generate_sbom(output_directory: Path) -> None:
    validate()
    output_directory.mkdir(parents=True, exist_ok=True)
    commit = os.environ.get("GITHUB_SHA", "working-tree")
    if commit != "working-tree" and not SHA_RE.fullmatch(commit):
        fail("GITHUB_SHA is non-canonical")
    timestamp = source_timestamp()
    components = collect_components()
    atomic_json(output_directory / "repository.cdx.json", cyclonedx_document(components, timestamp, commit))
    atomic_json(output_directory / "repository.spdx.json", spdx_document(components, timestamp, commit))
    print(f"sbom: passed components={len(components)} output={output_directory}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate", help="validate pinned dependencies and build sources")
    provenance_parser = subparsers.add_parser("provenance", help="verify and attest the CI runner")
    provenance_parser.add_argument("--output", required=True, type=Path)
    sbom_parser = subparsers.add_parser("sbom", help="generate CycloneDX and SPDX JSON SBOMs")
    sbom_parser.add_argument("--output-dir", required=True, type=Path)
    audit_parser = subparsers.add_parser(
        "verify-audit", help="verify that pip-audit covered every hash-locked component"
    )
    audit_parser.add_argument("--audit", required=True, type=Path)
    audit_parser.add_argument("--requirements", required=True, type=Path)
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.command == "validate":
            validate()
        elif arguments.command == "provenance":
            provenance(arguments.output)
        elif arguments.command == "sbom":
            generate_sbom(arguments.output_dir)
        elif arguments.command == "verify-audit":
            verify_audit(arguments.audit, arguments.requirements)
        else:
            fail(f"unsupported command: {arguments.command}")
    except PolicyError as error:
        print(f"supply-chain-policy: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
