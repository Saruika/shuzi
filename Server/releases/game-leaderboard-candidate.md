# Game leaderboard local candidate — server 1.5.13.16

This is a local release preparation record, not a production deployment or TestFlight acceptance record. The historical `v1.4.0-build6-acceptance5.md` record is unchanged. No production script, account mutation, schema installation, APNs send, SMTP send or publication was performed to produce this record.

## Reviewed release graph

The release contains 37 files: the thin plugin entry, Composer metadata and the complete reviewed vendor tree. The isolated evaluator streams exactly eleven length-framed and individually SHA-256-checked sources in this order:

1. `trait-shuzijun-app-collaboration.php`
2. `trait-shuzijun-app-fan-endpoints.php`
3. `trait-shuzijun-app-push-notifications.php`
4. `trait-shuzijun-app-fan-identity.php`
5. `trait-shuzijun-app-content-delivery.php`
6. `trait-shuzijun-app-game-leaderboard.php`
7. `class-shuzijun-collaboration-private-payload.php`
8. `class-shuzijun-game-rules.php`
9. `game-rules-v1.json`
10. `class-shuzijun-app-content-api.php`
11. `shuzijun-app-content.php`

The first ten files are under `vendor/shuzijun/app-content/`. The core's runtime load order is separately checked: collaboration cipher, collaboration trait, fan endpoints, push notifications, fan identity, content delivery, game rules class, game leaderboard trait. Exact expected loaders are removed only from the isolated in-memory evaluator; production loading remains unchanged. Extra loaders and changed ordering are rejected.

The JSON is data, never PHP-evaluated. Its byte hash must also equal `Shuzijun_Game_Rules::FILE_SHA256`, then its decoded value must pass the actual rules-class constructor. The pinned document has six origins, 108 events with four options each, 28 endings and three immediate endings. The evaluator cannot exercise `bundled()` filesystem resolution because it runs with `open_basedir=/nonexistent`; the independent game-rules regression must also pass using the real same-directory bundled file.

## Retained deployment gates

- Candidate manifests remain restricted to the reviewed legacy bridge or this new candidate. The older modular and previous monolithic manifests are retained only as valid live/rollback baselines, not newly deployable candidates.
- The sole unmanifested legacy bridge transition, byte-exact manifest checks, complete file coverage, symlink/secret/residue rejection, root ownership, restricted permissions, authority locks and backup-integrity checks remain required.
- Collaboration Phase 1 remains hard-disabled even with the external opt-in set to true. No leaderboard release opens the collaboration fuse.
- The probe remains filesystem-confined, network-disabled, unprivileged and time-limited. Unknown source graphs, framing, hashes, JSON or loader changes fail closed.
- Every direct module URL, now including the rules JSON, must still return **404**. A 403 is not silently accepted by this release. Any server configuration incompatibility must be reported, not bypassed.
- PHP lint, Composer validation/audit/platform requirements, installed autoload validation, webroot/authority checks, backup creation and fail-closed rollback remain unchanged. No production deployment is authorized by this document.
- Any leaderboard schema setup is a separate explicit deployment action; ordinary GET/POST acceptance must not be used to create a schema. App/website privacy publication and App Store disclosures must be verified before public release.
- The existing `upgrade-review-plugin.py` remains a historical, exact `5038c807...` → `2b632ca1...` transition, replacing only existing files. It does **not** support this candidate's three added leaderboard/rules files. Before upgrading an existing review environment, implement and locally verify a separately pinned, new-file-aware transaction with presence-sensitive rollback and foreign-change rejection; do not merely replace the old target hash or invoke the one-time bootstrap against an existing site. This review-upgrade work remains pending.

## Exact trust values

```text
RELEASE_MANIFEST_SHA256=3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576
PLUGIN_ENTRY_SHA256=b38f8fae4df5ae4f3513666d14da917ae8a10aa22f4eb3bc38b86848f6d4ed96
CORE_CLASS_SHA256=ada9de238bcb239bc72cd8647b0144d90836ead40606238f3f668ba38a4184cb
COLLABORATION_CIPHER_SHA256=bdcea372748c79a06284f01570d0863d20316bf3d4d33fe7924c16d100a1b1d7
COLLABORATION_TRAIT_SHA256=7175ae3aefb1add1af504c2bbbba355b5e448a81818d7c00ace12c37cc6dc4e5
FAN_ENDPOINTS_TRAIT_SHA256=bd689473956b67b480ce62704b73d39ea6c7a9536a19496120722d2524f65160
PUSH_NOTIFICATIONS_TRAIT_SHA256=7c5be7cf3347b187f6c88a12ad6a21f0001a5e7c92edbfe7a99e834abc1eebb7
FAN_IDENTITY_TRAIT_SHA256=c5f6647843ee58f7db268654cfcbba73d92404d0e3ea4d2e3ac7db9d25199d65
CONTENT_DELIVERY_TRAIT_SHA256=f27863d35b6a701d45afd6bfcecb5b235983497fee71553d18ec801bcbec2d6a
GAME_LEADERBOARD_TRAIT_SHA256=5d535654e713b60a58059087a35ca086ff35e12cd0e859a302850fb56058fbd9
GAME_RULES_CLASS_SHA256=a75a0b61fe46be1bfe0993c2266b54fc2b30c8766ac8a3efb5fe30e098a1ff09
GAME_RULES_JSON_SHA256=1ee7357cbd5018f84618ea610e8c8b648b9857ce22f05d91c91eb052cd36fdf1
PREVIOUS_LIVE_MANIFEST_SHA256=5038c807d0e15a54b4acb20a7e9fe43ac23e90339708f0cb65561a8730c3acfe
PREVIOUS_MODULAR_MANIFEST_SHA256=2b632ca195a65f1f0309bf66a9098ef52ca49a5eec9d80a5b7d9c32b8fbdfdee
LEGACY_BRIDGE_MANIFEST_SHA256=64aee00b4bb78903577ae9de737eb1cfdd3aae687c7633483fa410b8b09d4134
DEPLOYER_SHA256=afa1f6282292fee2a192b9946bb72c8277f1b4027ff9c82a8ac6f96f7a7a44a8
STANDBY_SEEDER_SHA256=d2a9dee08f37c92b900981e36b5331dd7e24bb95e8de202d201f4ff534e9d652
```

Any payload or deployer change invalidates these values and requires a new local review and regenerated exact hashes; do not widen the allowlist to work around drift.

## Local validation scope

The executable evaluator probe passed 14 valid/invalid cases using the locally built official PHP 8.3.33 CLI: exact graph, changed hash, truncated/trailing framing, missing JSON, reordered traits/loaders, four unknown loader forms, JSON/class hash mismatch, malformed schema with matching hash, and hard-off fuse enforcement. The final local runtime includes OpenSSL, Sodium, Phar and zlib; the full PHP plugin contract and locked Composer audit also passed separately. These remain local checks, not evidence of the production runtime or platform. The exact deployment-form Composer validation (`--strict --no-check-all --no-check-publish`) passed; plain strict validation reports the intentional exact-version constraint as a recommendation warning.

The deployment contract test and push-notification contract test passed against this record, as did `bash -n` for the deployer and the scoped whitespace/diff check. Production preflight, production URL protection, database schema/application deployment, App UI acceptance and publication remain separate pending gates; no local result substitutes for them.
