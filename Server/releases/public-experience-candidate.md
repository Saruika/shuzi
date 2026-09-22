# Public experience candidate — server 1.5.13.17

2026-09-22. Server code deployed to standby then authority; the owner-approved
metadata repair and fixed six-image publication were committed on the authority.
No original/derivative image writes, notifications, full-site sync, Git push,
TestFlight upload or Apple review submission. Website privacy content was not
changed by this narrowly authorized operation.

## Independent public boundary

`GET /wp-json/shuzijun/v1/public-experience` accepts no login requirement and
returns only `schemaVersion`, `contentAudience: public`, `updatedAt` and `albums`.
Albums contain only `id/title/subtitle/images`; images contain `id/url/altText`.
The selection is empty until an administrator explicitly saves image IDs. It does
not reuse the legacy manifest's misleading `public` audience (approved-account
three-image entitlement), hero, portrait, videos, private galleries or user data.
Existing protected endpoints retain their approval/Douyin/session checks.

At most 30 albums, 6 selected images per album; text limits are 160/400/400 Unicode
characters. Draft/hidden albums, removed/trashed images and invalid selections are
omitted. Only trusted uploads URLs without query/path ambiguity and existing
640–1600px, uncropped derivatives qualify. No original fallback or disk image cache.
The account-authority gate and no-store response policy remain unchanged.

Website configuration: edit a portfolio → “公开体验区精选照片”. Every selection is
explicit; nonce, management capability, edit permission, source membership,
optimistic revision, publication lock and actor lock are checked. Empty selection
withdraws public listing. Uploads get a future uncropped 1600px size; this does not
regenerate or overwrite old images. Known static image URLs remain individually
reachable under the pre-existing media/CDN policy; withdrawing a listing is not
cryptographic revocation of a URL already received.

## Fixed first publication — applied

The owner selected the current first three albums, two photos each. Resolve once,
never dynamically select the first three again:

| Album ID | Current title | Exact selected image IDs |
| --- | --- | --- |
| 6 | 婚纱作品 | 18, 19 |
| 7 | 新中式 | 33, 34 |
| 39 | 旗袍 | 76, 77 |

The main-node `post_date ASC, ID ASC` order and each gallery's first two IDs were
read from SQL. All six existing 1536px derivatives are real JPEG files and return
HTTPS 200 with `image/jpeg` (HEAD only, no local photo download). Actual bytes:
111817, 105982, 226151, 270901, 183548, 195095 respectively.

Read-only preflight (exit 2 blocks the entire selection, never silently five):

```sh
python3 Server/operations/check-public-experience-selection.py --dry-run
```

Resolved blocker: image 18 metadata pointed to `2026/03/2023-12-19-024812.jpg`,
1400×2093, without `original_image`. `_wp_attached_file` points to
`2026/03/2023-12-19-024812-scaled.jpg`, actually 1712×2560. This is stale metadata,
not a consistent WordPress scaled pair. Its selected derivative is 1027×1536.
Pre-repair raw metadata SHA256 was
`2504f01680af781b15097409ba49ce58e85c0163804e4b3055719ca42dfa6b13`.

File checksums were verified unchanged before and after the approved repair:

- Old `.jpg`: `c6eb75a5271a3a9ef5a30de8411b40b1bced6deca9b55c115e771abcdbd4c61c`
- Current `-scaled.jpg`: `b5f0296fc1fcf487bc6fac74722bf32edeb7b7e80fef36ce2cdd4c0cfc31070d`
- Selected `-1027x1536.jpg`: `7961c1432b2f02ffc33007aafd9c426911e2fc51927529a785dccd6a911d0013`

Repair preparation: acquire the site-operation lock and the editorial publication
lock; durable backup of exact image-18 `_wp_attachment_metadata` row(s), selected
albums' `_yishu_public_preview_media` presence/values and updated-at option.
Recheck all IDs, gallery membership, metadata hash and above image hashes under
lock. Correct only metadata `file/width/height/filesize` to the actual current
attachment; preserve image bytes, existing sizes and all other metadata. Do not
invent an `original_image` or regenerate/overwrite photos. Invalidate image-18
post/object metadata cache. Rerun preflight; all six must pass before saving the
fixed selections. After publication check exact anonymous six-image DTO and that
anonymous `/app-content` remains rejected. Failure restores the backed-up values
and invalidates the same caches, without rolling back unrelated data. The
writer is now implemented and accepted as described below; the independent checker
intentionally has no apply mode.

### Deployment and data receipts

- Both live release manifests: `ae94b05f340b82842cca32beddb2c6ad7a9b69929ac97805a59f823ea28ff8ed`.
- Standby code backup: `/var/backups/shuzijun-app-content/20260922T144150Z-ae94b05f340b-927850`.
- Authority code backup: `/var/backups/shuzijun-app-content/20260922T144205Z-ae94b05f340b-562634`.
- Reviewed deployer was staged as `/run/deploy-app-content-public-20260922`;
  the installed `/usr/local/sbin/deploy-app-content-release` was not replaced.
- Data helper directory: `/var/lib/shuzijun-app-content/public-selection-20260922`.
  Writer SHA256 `ca1e99bc39a83837d3f71750e03163f0764f6f070c35346ec7d1684f6c07702b`;
  bootstrap library SHA256 `fdfe2c587a565b79460745a00baeb276b92782d8ece7fa4851566b990098e1a3`.
- Data receipt directory: `/var/backups/shuzijun-app-content/public-selection-1fe0b6d9e1604cb18a09488a8328d021`.
  Both JSON files are root:root 0600 regular single-link files.
  `before.json`: `20cdaf347493cd5c753defdf3a2201c2a7566d92cfb464693fadadff4193b164`;
  `after.json`: `48236ebd449d715269576e8e3b9f7dc1718b3c95321a883c14879d3467987a45`.
- Image 18 repaired metadata SHA256: `81ad6184bb99f5c051e5e27801f4e01a0efc6973f122aa9891f7c6acffd91192`.
  Only `file/width/height/filesize` changed. Other metadata and every image byte remain unchanged.
- The writer uses one non-reconnecting global wpdb connection, an isolated
  process-only cache during the transaction, and targeted shared-cache deletion
  only after commit. Before/after receipts are durable before COMMIT. Failure
  preserves receipts; do not blindly retry an unknown commit result.
- Initial apply was rejected before mutation due to `site_operation_busy`.
  After checking the scheduled service had ended and the lock was free, apply
  succeeded. Post-apply dry-run reports `changeNeeded:false`; independent preflight
  reports `ready:true`, zero issues.
- Public, direct authority and standby pretty-URL proxy return exactly the fixed
  three albums / six images, schema-only fields and no-store; six JPEG HEADs return
  direct 200. Anonymous protected `/app-content` remains 401. Standby's local
  protected query route remains 503; its public query route is an independent
  local public catalogue, not evidence of replicated DB publication.
- No full-site sync was started; standby DB metadata awaits ordinary synchronization.
  Code, service states and all five temporarily paused timers were verified restored.

The exact reversible data rollback command, only if separately needed and after
checking no subsequent editor changes:

```sh
sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C LANG=C \
  /usr/bin/php8.3 /var/lib/shuzijun-app-content/public-selection-20260922/apply-public-experience-selection.php \
  rollback=1fe0b6d9e1604cb18a09488a8328d021
```

Rollback refuses to overwrite foreign edits and restores only owned rows, their
raw values/IDs or original absence; it never writes image files. No production
rollback was exercised solely for testing. Synthetic fault/rollback tests: 103 passed.
Evidence root: `/Users/mathiashu/Library/Developer/Hi-Shuzi-QA/public-deploy-20260922.7Olwsh`.
`live-public-native.xcresult`: the actual candidate Swift anonymous transport and
production DTO policy passed against live data (1 passed, 0 failed, 0 skipped).
All six image HEAD requests met direct-200/JPEG/size/filename-dimension checks;
this does not claim pixel decoding or visual acceptance. Capture protection
remained enabled and no photographs were saved locally.
Post-deployment `security-check-postdeploy-py312.log` completed with exit 0;
seven environment-limited tests explicitly skipped. An earlier attempt used
system Python 3.9 because of an overly narrow PATH and stopped at unsupported
type syntax; it is retained as `security-check-postdeploy.log`, not called a pass.
The complete rerun used the existing Python 3.12 runtime without weakening tests.
Read-only sync inspection confirms ordinary version-2 transfers carry only SQL
and uploads, not the App code unit, and health records rather than pins the App
release hash. Leaving the older installed App deployer does not introduce a
known manifest gate into normal synchronization; the next scheduled run was not
executed or pre-certified by this task.

## Release graph and gates

The release has 38 files. The isolated evaluator consumes exactly twelve framed,
hashed sources: the prior six traits, the new public-experience trait, collaboration
cipher, game-rules class, rules JSON, core class, plugin entry. The core loader graph
has the new trait immediately after content delivery. Old live/rollback manifests
remain accepted, including the previous game release; it is not a new candidate.
The fixed target hash, source graph, confined/no-network evaluator, hard-disabled
collaboration fuse, backup, authority, direct module denial and rollback gates are
retained. Deploy only through the updated, verified release deployer. No ad-hoc copy.

```text
RELEASE_MANIFEST_SHA256=ae94b05f340b82842cca32beddb2c6ad7a9b69929ac97805a59f823ea28ff8ed
PLUGIN_ENTRY_SHA256=64159cb211d3228494ee73b91f884f7c30a46d7c249c79741d31bae19d71e2af
CORE_CLASS_SHA256=a27bbdb16baee766b4895b63f250de97226f1e7c5d5524f4bf0ad5099e1944a4
COLLABORATION_CIPHER_SHA256=bdcea372748c79a06284f01570d0863d20316bf3d4d33fe7924c16d100a1b1d7
COLLABORATION_TRAIT_SHA256=7175ae3aefb1add1af504c2bbbba355b5e448a81818d7c00ace12c37cc6dc4e5
FAN_ENDPOINTS_TRAIT_SHA256=bd689473956b67b480ce62704b73d39ea6c7a9536a19496120722d2524f65160
PUSH_NOTIFICATIONS_TRAIT_SHA256=7c5be7cf3347b187f6c88a12ad6a21f0001a5e7c92edbfe7a99e834abc1eebb7
FAN_IDENTITY_TRAIT_SHA256=c5f6647843ee58f7db268654cfcbba73d92404d0e3ea4d2e3ac7db9d25199d65
CONTENT_DELIVERY_TRAIT_SHA256=f27863d35b6a701d45afd6bfcecb5b235983497fee71553d18ec801bcbec2d6a
GAME_LEADERBOARD_TRAIT_SHA256=5d535654e713b60a58059087a35ca086ff35e12cd0e859a302850fb56058fbd9
PUBLIC_EXPERIENCE_TRAIT_SHA256=58a07e016adea07b27652e88b95efb96dbcb228d7dc9d03f2109722b26584b8e
GAME_RULES_CLASS_SHA256=a75a0b61fe46be1bfe0993c2266b54fc2b30c8766ac8a3efb5fe30e098a1ff09
GAME_RULES_JSON_SHA256=1ee7357cbd5018f84618ea610e8c8b648b9857ce22f05d91c91eb052cd36fdf1
PREVIOUS_LIVE_MANIFEST_SHA256=5038c807d0e15a54b4acb20a7e9fe43ac23e90339708f0cb65561a8730c3acfe
PREVIOUS_MODULAR_MANIFEST_SHA256=2b632ca195a65f1f0309bf66a9098ef52ca49a5eec9d80a5b7d9c32b8fbdfdee
PREVIOUS_GAME_MANIFEST_SHA256=3adaebe7acbdeeb189a703c865f991935cf90a778a8151eaf85f272e7d053576
DEPLOYER_SHA256=04ff69bd5aa66d4f7a28e86129ef36c32d74481cec90ede61faf19a0205d3ae0
STANDBY_SEEDER_SHA256=120303e90e7ba7fb5f000a7c00bc0fc8ad8c36f92fb99f327b0c478dc2fb7ee9
```

Local evidence: public trait 48 synthetic assertions passed; existing bound-admin
authentication 56 assertions passed; plugin-contract passed using local PHP 8.3
and `OPENSSL_CONF=/etc/ssl/openssl.cnf`. See the deployment receipts above for
separate production evidence. Synthetic tests are not real WordPress admin UI
or App Store acceptance evidence.
