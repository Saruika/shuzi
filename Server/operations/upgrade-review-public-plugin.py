#!/usr/bin/env python3
"""Pinned review-only public API upgrade; default is a read-only preflight.

Reuses the byte-pinned historical transaction engine, not a generic updater.
Only 1.5.13.16 -> 1.5.13.17 is accepted. No media, account, selection, schema,
isolation, production configuration, or original-image changes are made.
The new anonymous catalog must be empty before this code-only step completes.

Stage this script and its three pinned sibling dependencies as root-owned
protected files outside the webroot. Use --source with the exact 38-file plugin
bundle; add --apply only after the default preflight succeeds. A failure leaves
both review services stopped. --restore BACKUP uses the same verified durable
receipts as the engine (the historical game-plugin-backup-* prefix is retained).
Never restart a failed transaction without checking its exact restored state.
"""
import hashlib
import importlib.util
from pathlib import Path


DEPENDENCIES = {
    'upgrade-review-game-plugin.py': '6829d379f3b7aa213f56d636c7c07baee59341141ea25a01aaf888e6896a87c3',
    'accept-review-bootstrap.py': '82a4583aaca627fdc1ae137cfa8098425a1e634c0bc9feeaa08a0b87c647d76e',
    'provision-review-bootstrap.py': '494ad787c77a535ce62b2b7d9f6b57519d3a5ce8981094cc21720c157a64efa2',
}


def load_engine():
    directory = Path(__file__).resolve().parent
    for name, expected in DEPENDENCIES.items():
        dependency = directory / name
        if dependency.is_symlink() or not dependency.is_file():
            raise RuntimeError('Missing or linked pinned review dependency')
        if hashlib.sha256(dependency.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Unreviewed review transaction dependency')
    spec = importlib.util.spec_from_file_location(
        'public_review_transaction', directory / 'upgrade-review-game-plugin.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # These are the only transition parameters changed from the pinned engine.
    # Its locking, exact graph checks, ownership/metadata guards, immutable
    # isolation checks, atomic writes, fsync receipts and rollback stay intact.
    module.BASELINE = '3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576'
    module.TARGET = 'ae94b05f340b82842cca32beddb2c6ad7a9b69929ac97805a59f823ea28ff8ed'
    module.CHANGED = (module.PREFIX + 'class-shuzijun-app-content-api.php',
                      'shuzijun-app-content.php')
    module.ADDED = (module.PREFIX + 'trait-shuzijun-app-public-experience.php',)
    module.WRITE_ORDER = module.ADDED + module.CHANGED
    return module


engine = load_engine()
original_wait_for_php = engine.b.wait_for_php


def verify_empty_public_catalog():
    status, payload = engine.a.request('public-experience')
    engine.check(status == 200 and isinstance(payload, dict)
                 and set(payload) == {'schemaVersion', 'contentAudience', 'updatedAt', 'albums'}
                 and type(payload['schemaVersion']) is int and payload['schemaVersion'] == 1
                 and payload['contentAudience'] == 'public'
                 and isinstance(payload['updatedAt'], str) and bool(payload['updatedAt'])
                 and payload['albums'] == [],
                 'anonymous public API must be valid and empty after code-only upgrade')


def wait_for_public_php():
    original_wait_for_php()
    # This runs inside the original engine's health-check try/rollback scope,
    # before it verifies private endpoints and writes the completed receipt.
    verify_empty_public_catalog()


engine.b.wait_for_php = wait_for_public_php


def main():
    # The same CLI, exact protected source gate and review-only maintenance lock
    # apply. There is no flag for changing hashes, units, paths, or selections.
    engine.main()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        label = str(error) if isinstance(error, engine.ReviewGameError) else type(error).__name__
        print('review-public: failed: ' + label
              + '; inspect backup; do not restart isolated services without verification')
        raise SystemExit(1) from None
