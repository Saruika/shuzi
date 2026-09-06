#!/usr/bin/env python3
"""Local contract tests for the CI supply-chain gate."""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from importlib.resources import files
from pathlib import Path
from types import ModuleType

import jsonschema
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci-supply-chain.py"
WORKFLOW = ROOT / ".github/workflows/ios-quality.yml"
# Current reviewed materials get a new record; immutable historical releases
# must not be rewritten to pretend they contained today's workflow/scripts.
RELEASE_RECORD = ROOT / "Server/releases/v1.4.0-build4-review-env-preview19.md"
SPDX_SCHEMA_URL = (
    "https://raw.githubusercontent.com/spdx/spdx-spec/"
    "aadf3b0b8dbbabdb4d880b0fc714255fea436ff7/schemas/spdx-schema.json"
)
SPDX_SCHEMA_SHA256 = "239208b7ac287b3cf5d9a9af23f9d69863971102a5e1587a27a398b43490b89b"


def load_script() -> ModuleType:
    loader = importlib.machinery.SourceFileLoader("ci_supply_chain", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


def run_script(*arguments: str, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_environment = os.environ.copy()
    if environment:
        merged_environment.update(environment)
    return subprocess.run(
        [sys.executable, str(SCRIPT), *arguments],
        cwd=ROOT,
        env=merged_environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )


def test_fail_closed_parsers(module: ModuleType, temporary: Path) -> None:
    assert module.IMAGE_VERSION_RE.fullmatch("20260428.39")
    assert module.IMAGE_VERSION_RE.fullmatch("20260428.0039.1")
    for invalid_image_version in ("", "20260428", "2026.1", "20260428.1.2.3", "20260428.latest"):
        assert module.IMAGE_VERSION_RE.fullmatch(invalid_image_version) is None

    ranged = temporary / "ranged.txt"
    ranged.write_text("fastapi>=0.141.1,<1\n", encoding="utf-8")
    try:
        module.parse_requirements(ranged, hashes_required=False)
    except module.PolicyError:
        pass
    else:
        raise AssertionError("moving Python dependency range was accepted")

    unhashed = temporary / "unhashed.txt"
    unhashed.write_text("ruff==0.16.5\n", encoding="utf-8")
    try:
        module.parse_requirements(unhashed, hashes_required=True)
    except module.PolicyError:
        pass
    else:
        raise AssertionError("unhashed quality dependency was accepted")

    duplicate = temporary / "duplicate.txt"
    duplicate.write_text("typing_extensions==4.16.0\ntyping-extensions==4.16.0\n", encoding="utf-8")
    try:
        module.parse_requirements(duplicate, hashes_required=False)
    except module.PolicyError:
        pass
    else:
        raise AssertionError("normalized duplicate dependency was accepted")

    moving_action = temporary / "moving.yml"
    moving_action.write_text("steps:\n  - uses: actions/checkout@main\n", encoding="utf-8")
    try:
        module.validate_actions(moving_action)
    except module.PolicyError:
        pass
    else:
        raise AssertionError("moving GitHub action reference was accepted")

    unreviewed_action = temporary / "unreviewed.yml"
    unreviewed_action.write_text(f"steps:\n  - uses: evil/action@{'1' * 40}\n", encoding="utf-8")
    try:
        module.validate_actions(unreviewed_action)
    except module.PolicyError:
        pass
    else:
        raise AssertionError("unreviewed pinned GitHub action was accepted")


def test_audit_coverage(module: ModuleType, temporary: Path) -> None:
    requirements_path = ROOT / ".github/requirements-quality.txt"
    requirements = module.parse_requirements(requirements_path, hashes_required=True)
    audit_path = temporary / "quality-audit.cdx.json"
    components = [
        {"type": "library", "name": name, "version": requirement.version}
        for name, requirement in requirements.items()
    ]
    payload = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.4",
        "components": components,
    }
    audit_path.write_text(json.dumps(payload), encoding="utf-8")
    result = run_script(
        "verify-audit",
        "--requirements",
        ".github/requirements-quality.txt",
        "--audit",
        str(audit_path),
    )
    assert result.returncode == 0, result.stderr
    assert f"components={len(requirements)}" in result.stdout

    payload["components"] = components[:-1]
    audit_path.write_text(json.dumps(payload), encoding="utf-8")
    result = run_script(
        "verify-audit",
        "--requirements",
        ".github/requirements-quality.txt",
        "--audit",
        str(audit_path),
    )
    assert result.returncode == 1
    assert "component coverage differs" in result.stderr


def test_sboms(temporary: Path) -> None:
    output = temporary / "sbom"
    result = run_script("sbom", "--output-dir", str(output), environment={"SOURCE_DATE_EPOCH": "0"})
    assert result.returncode == 0, result.stderr

    cyclonedx = json.loads((output / "repository.cdx.json").read_text(encoding="utf-8"))
    schema_root = files("cyclonedx.schema._res")
    schema = json.loads(schema_root.joinpath("bom-1.6.SNAPSHOT.schema.json").read_text())
    jsf_schema = json.loads(schema_root.joinpath("jsf-0.82.SNAPSHOT.schema.json").read_text())
    spdx_license_schema = json.loads(schema_root.joinpath("spdx.SNAPSHOT.schema.json").read_text())
    registry = Registry().with_resources(
        [
            (schema["$id"], Resource.from_contents(schema)),
            (
                "http://cyclonedx.org/schema/jsf-0.82.SNAPSHOT.schema.json",
                Resource.from_contents(jsf_schema),
            ),
            (
                "http://cyclonedx.org/schema/spdx.SNAPSHOT.schema.json",
                Resource.from_contents(spdx_license_schema),
            ),
        ]
    )
    schema_errors = sorted(
        jsonschema.Draft7Validator(schema, registry=registry).iter_errors(cyclonedx),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    assert not schema_errors, schema_errors[0].message
    assert cyclonedx["bomFormat"] == "CycloneDX"
    assert cyclonedx["specVersion"] == "1.6"
    assert cyclonedx["metadata"]["timestamp"] == "1970-01-01T00:00:00Z"
    cyclonedx_refs = [component["bom-ref"] for component in cyclonedx["components"]]
    assert len(cyclonedx_refs) == len(set(cyclonedx_refs))
    for component in cyclonedx["components"]:
        properties = {property_["name"]: property_["value"] for property_ in component["properties"]}
        expected_scope = "required" if properties["shuzijun:dependency-scope"] == "runtime" else "excluded"
        assert component["scope"] == expected_scope
    assert any(reference.startswith("pkg:pypi/app-store-server-library@3.1.2") for reference in cyclonedx_refs)
    assert any(reference.startswith("pkg:composer/firebase/php-jwt@7.1.0") for reference in cyclonedx_refs)
    assert any(reference.startswith("pkg:github/actions/checkout@") for reference in cyclonedx_refs)

    spdx = json.loads((output / "repository.spdx.json").read_text(encoding="utf-8"))
    request = urllib.request.Request(SPDX_SCHEMA_URL, headers={"User-Agent": "yishu-ci/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        spdx_schema_bytes = response.read(1_000_001)
    assert len(spdx_schema_bytes) <= 1_000_000
    assert hashlib.sha256(spdx_schema_bytes).hexdigest() == SPDX_SCHEMA_SHA256
    spdx_schema = json.loads(spdx_schema_bytes.decode("utf-8"))
    spdx_schema_errors = sorted(
        jsonschema.Draft7Validator(spdx_schema).iter_errors(spdx),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    assert not spdx_schema_errors, spdx_schema_errors[0].message
    assert spdx["spdxVersion"] == "SPDX-2.3"
    assert spdx["dataLicense"] == "CC0-1.0"
    package_ids = [package["SPDXID"] for package in spdx["packages"]]
    assert len(package_ids) == len(set(package_ids))
    assert len(spdx["relationships"]) == len(spdx["packages"])
    assert any(
        relationship["relationshipType"] == "DEV_DEPENDENCY_OF"
        for relationship in spdx["relationships"]
    )


def test_local_provenance(temporary: Path) -> None:
    output = temporary / "runner-provenance.json"
    tool_directory = temporary / "tools"
    tool_directory.mkdir()
    php = tool_directory / "php"
    php.write_text("#!/bin/sh\nprintf '8.3.6'\n", encoding="utf-8")
    php.chmod(0o755)
    composer = tool_directory / "composer"
    composer.write_text(
        "#!/bin/sh\nprintf 'Composer version 2.9.8 2026-08-21 00:00:00'\n",
        encoding="utf-8",
    )
    composer.chmod(0o755)
    environment = {
        "GITHUB_ACTIONS": "true",
        "GITHUB_REPOSITORY": "Saruika/shuzi",
        "GITHUB_SHA": "1" * 40,
        "GITHUB_WORKFLOW_REF": "Saruika/shuzi/.github/workflows/ios-quality.yml@refs/heads/main",
        "GITHUB_RUN_ID": "1",
        "GITHUB_RUN_ATTEMPT": "1",
        "CI_RUNNER_LABEL": "macos-26",
        "CI_RUNNER_ENVIRONMENT": "github-hosted",
        "CI_PHP_VERSION": "8.3",
        "CI_COMPOSER_VERSION": "2.9.8",
        "RUNNER_OS": "macOS",
        "RUNNER_ARCH": "ARM64",
        "RUNNER_NAME": "local-contract-fixture",
        "ImageOS": "macos26",
        "ImageVersion": "20260904.0001.1",
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        "PATH": f"{tool_directory}{os.pathsep}{os.environ['PATH']}",
    }
    result = run_script("provenance", "--output", str(output), environment=environment)
    assert result.returncode == 0, result.stderr
    record = json.loads(output.read_text(encoding="utf-8"))
    assert record["subject"]["commit"] == "1" * 40
    assert record["runner"]["image_version"] == "20260904.0001.1"
    assert record["runner"]["image_source"] == "https://github.com/actions/runner-images"
    assert record["runner"]["image_definition"] == (
        "images/macos/macos-26-arm64-Readme.md"
    )
    assert record["runner"]["image_revision_strategy"] == "record-and-attest-every-run"
    assert record["toolchain"]["xcode_version"] == "26.6"
    assert record["toolchain"]["python_version"] == "3.13.15"
    assert len(record["toolchain"]["python_sha256"]) == 64
    assert record["toolchain"]["php_version"] == "8.3.6"
    assert record["toolchain"]["php_version_line_policy"] == "8.3"
    assert record["toolchain"]["php_version_strategy"] == (
        "minor-line-record-and-attest-every-run"
    )
    assert record["toolchain"]["composer_version"] == "2.9.8"
    assert len(record["toolchain"]["php_sha256"]) == 64
    assert len(record["toolchain"]["composer_sha256"]) == 64
    assert len(record["materials"]) == 15
    assert "Scripts/ci-supply-chain.py" in record["materials"]
    assert "Scripts/ci-release-analyze.sh" in record["materials"]
    assert "Server/entitlement-verifier/requirements.in" in record["materials"]
    assert "Yishu.xcodeproj/project.pbxproj" in record["materials"]


def test_workflow_text() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "persist-credentials: false" in text
    triggers = text.split("permissions:", 1)[0]
    assert triggers.count("paths-ignore:") == 1
    assert "Server/" not in triggers and "**/*.md" not in triggers
    assert "pull_request:\n  workflow_dispatch:" in triggers
    assert "runs-on: macos-26" in text
    # Keep sufficient bounded headroom for both serial device families and
    # Release analysis; do not silently fall back to GitHub's longer default.
    job_configuration = text.split("  quality:\n", 1)[1].split("    steps:\n", 1)[0]
    timeout_lines = [line for line in job_configuration.splitlines() if "timeout-minutes:" in line]
    assert timeout_lines == ["    timeout-minutes: 180"]
    assert "Scripts/ci-ios-tests.sh iPhone" in text
    assert "Scripts/ci-ios-tests.sh iPad" in text
    assert "Scripts/ci-release-analyze.sh" in text
    assert "continue-on-error:" not in text
    python_setup = text.split("- name: Set up audited Python", 1)[1].split("- name:", 1)[0]
    assert "python-version: ${{ env.CI_PYTHON_VERSION }}" in python_setup
    assert "architecture: arm64" in python_setup
    assert "check-latest: false" in python_setup
    assert "CI_PYTHON_VERSION: '3.13.15'" in text
    assert "CI_PHP_VERSION: '8.3'" in text
    assert "if: always()" in text
    assert "retention-days: 30" in text
    assert "--require-hashes" in text
    assert "--format cyclonedx-json" in text
    assert text.count("\n            --disable-pip \\\n") == 2
    assert text.count("Scripts/ci-supply-chain.py verify-audit") == 2
    assert "Run Python SAST with Bandit" in text
    assert "Run Swift compiler analysis and audit Release bundle" in text
    assert "--exclude Server/tests,Server/vendor" in text
    assert "Server/operations \\" in text
    release_analyze = (ROOT / "Scripts/ci-release-analyze.sh").read_text(encoding="utf-8")
    assert "GCC_TREAT_WARNINGS_AS_ERRORS=YES" in release_analyze
    assert "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" in release_analyze
    assert "--requirement Server/entitlement-verifier/requirements.txt" in text
    assert "--requirement .github/requirements-quality.txt" in text
    assert "python-runtime-audit.cdx.json" in text
    assert "python-quality-audit.cdx.json" in text
    assert "composer audit --locked --working-dir=Server" in text
    assert text.count("contents: read") == 1
    assert "write-all" not in text
    assert "contents: write" not in text
    assert "id-token: write" not in text


def verify_record_digest(text: str, name: str, digest: str) -> None:
    # Require exactly one complete assignment, not a substring in prose or a
    # second conflicting fingerprint. Name the stale material in CI output.
    values = re.findall(rf"^{re.escape(name)}=(.*)$", text, flags=re.MULTILINE)
    assert values == [digest], f"release record mismatch: {name} ({RELEASE_RECORD.name})"


def test_record_digest_rejects_stale_or_ambiguous_materials() -> None:
    name = "WORKFLOW_SHA256"
    digest = "a" * 64
    verify_record_digest(f"{name}={digest}\n", name, digest)
    for text in (
        "",
        f"{name}={'b' * 64}\n",
        f"{name}={digest}\n{name}={digest}\n",
        f"{name}={digest}\n{name}={'b' * 64}\n",
        f"prose {name}={digest}\n",
        f"{name}={digest}extra\n",
    ):
        try:
            verify_record_digest(text, name, digest)
        except AssertionError as error:
            assert name in str(error)
        else:
            raise AssertionError("stale or ambiguous release fingerprint was accepted")


def test_release_record() -> None:
    text = RELEASE_RECORD.read_text(encoding="utf-8")
    trust_materials = {
        "DEPENDABOT_SHA256": ROOT / ".github/dependabot.yml",
        "WORKFLOW_SHA256": WORKFLOW,
        "QUALITY_INPUT_SHA256": ROOT / ".github/requirements-quality.in",
        "QUALITY_LOCK_SHA256": ROOT / ".github/requirements-quality.txt",
        "RUNNER_POLICY_SHA256": ROOT / ".github/runner-policy.json",
        "RUNTIME_INPUT_SHA256": ROOT / "Server/entitlement-verifier/requirements.in",
        "RUNTIME_LOCK_SHA256": ROOT / "Server/entitlement-verifier/requirements.txt",
        "RUFF_POLICY_SHA256": ROOT / "Server/ruff.toml",
        "SUPPLY_CHAIN_SCRIPT_SHA256": SCRIPT,
        "RELEASE_ANALYZE_SHA256": ROOT / "Scripts/ci-release-analyze.sh",
        "TEST_SUMMARY_SHA256": ROOT / "Scripts/ci-test-summary.py",
        "DISTRIBUTION_CHECK_SHA256": ROOT / "Scripts/check-distribution-package.py",
    }
    for name, path in trust_materials.items():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        verify_record_digest(text, name, digest)
    verify_record_digest(text, "SPDX_2_3_SCHEMA_SHA256", SPDX_SCHEMA_SHA256)
    assert text.count("`v1.4.0-build4-review-env-preview19`") == 1


def main() -> None:
    module = load_script()
    validation = run_script("validate")
    assert validation.returncode == 0, validation.stderr
    assert "supply-chain-policy: passed" in validation.stdout
    with tempfile.TemporaryDirectory(prefix="ci-supply-chain-contract-") as temporary_name:
        temporary = Path(temporary_name)
        test_fail_closed_parsers(module, temporary)
        test_audit_coverage(module, temporary)
        test_sboms(temporary)
        test_local_provenance(temporary)
    test_workflow_text()
    test_record_digest_rejects_stale_or_ambiguous_materials()
    test_release_record()
    print("ci-supply-chain-contract-test: passed")


if __name__ == "__main__":
    main()
