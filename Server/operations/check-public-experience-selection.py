#!/usr/bin/env python3
"""Read-only preflight for the six explicitly approved public photographs.

No apply mode, original download, WordPress bootstrap, image processing, account
access, DB writes or deployment. Exit 2 means the whole selection is blocked;
never substitute images or silently publish fewer than the approved six.
"""
import json
import shlex
import subprocess
import sys

SELECTION = {6: [18, 19], 7: [33, 34], 39: [76, 77]}
WRAPPER = "/Users/mathiashu/Documents/Guai Website/.codex-temp/ssh_guai.sh"
SITE = "/var/www/html/shuzijun.com.cn"

SQL = """SELECT JSON_OBJECT('id',p.ID,'title',p.post_title,'type',p.post_type,'status',p.post_status,
'gallery',(SELECT meta_value FROM wp_postmeta WHERE post_id=p.ID AND meta_key='_portfolio_gallery' LIMIT 1),
'hidden',(SELECT meta_value FROM wp_postmeta WHERE post_id=p.ID AND meta_key='_app_is_hidden' LIMIT 1),
'selection',(SELECT meta_value FROM wp_postmeta WHERE post_id=p.ID AND meta_key='_yishu_public_preview_media' LIMIT 1),
'metadata',(SELECT meta_value FROM wp_postmeta WHERE post_id=p.ID AND meta_key='_wp_attachment_metadata' LIMIT 1),
'attached',(SELECT meta_value FROM wp_postmeta WHERE post_id=p.ID AND meta_key='_wp_attached_file' LIMIT 1))
FROM wp_posts p WHERE p.ID IN (6,7,39,18,19,33,34,76,77) ORDER BY p.ID"""

REMOTE_CHECK = r"""
$wanted = [6 => [18,19], 7 => [33,34], 39 => [76,77]];
$root = '/var/www/html/shuzijun.com.cn/wp-content/uploads/';
$rows = []; $issues = []; $checks = [];
while (($line = fgets(STDIN)) !== false) {
    if (trim($line) === '') { continue; }
    $row = json_decode(trim($line), true, 512, JSON_THROW_ON_ERROR);
    $rows[(int)$row['id']] = $row;
}
foreach ($wanted as $album => $ids) {
    $row = $rows[$album] ?? [];
    if (($row['type'] ?? '') !== 'portfolio' || ($row['status'] ?? '') !== 'publish'
        || ($row['hidden'] ?? '') === '1') { $issues[] = "album_{$album}_not_visible"; }
    $gallery = json_decode($row['gallery'] ?? '', true);
    if (!is_array($gallery)) { $gallery = []; }
    if (array_slice($gallery, 0, 2) !== $ids) { $issues[] = "album_{$album}_first_images_changed"; }
    $old = empty($row['selection']) ? [] : @unserialize($row['selection'], ['allowed_classes' => false]);
    if ($old !== [] && $old !== $ids) { $issues[] = "album_{$album}_selection_changed"; }
    foreach ($ids as $id) {
        if (!in_array($id, $gallery, true)) { $issues[] = "image_{$id}_not_in_approved_album"; }
        $image = $rows[$id] ?? [];
        $meta = @unserialize($image['metadata'] ?? '', ['allowed_classes' => false]);
        $attached = $image['attached'] ?? '';
        if (($image['type'] ?? '') !== 'attachment' || ($image['status'] ?? '') === 'trash'
            || !is_array($meta) || !is_string($attached)
            || !preg_match('#^2026/(03|08)/[A-Za-z0-9_.-]+\.jpg$#D', $attached)) {
            $issues[] = "image_{$id}_invalid_metadata"; continue;
        }
        $full = $root . $attached;
        $actual = @getimagesize($full);
        if (!$actual || $actual['mime'] !== 'image/jpeg') { $issues[] = "image_{$id}_file_missing"; continue; }
        if (($meta['file'] ?? null) !== $attached || ($meta['width'] ?? null) !== $actual[0]
            || ($meta['height'] ?? null) !== $actual[1]) { $issues[] = "image_{$id}_metadata_mismatch"; }
        $size = $meta['sizes']['1536x1536'] ?? [];
        $filename = $size['file'] ?? '';
        if (!is_string($filename) || !preg_match('/^[A-Za-z0-9_.-]+\.jpg$/D', $filename)) {
            $issues[] = "image_{$id}_preview_missing"; continue;
        }
        $relative = dirname($attached) . '/' . $filename;
        $preview = $root . $relative;
        $dimensions = @getimagesize($preview);
        if (!$dimensions || $dimensions['mime'] !== 'image/jpeg'
            || $dimensions[0] !== ($size['width'] ?? null) || $dimensions[1] !== ($size['height'] ?? null)
            || max($dimensions[0], $dimensions[1]) !== 1536
            || abs(($dimensions[0] / $dimensions[1]) / ($actual[0] / $actual[1]) - 1) > 0.02) {
            $issues[] = "image_{$id}_preview_invalid"; continue;
        }
        $checks[] = ['albumID'=>$album, 'imageID'=>$id, 'width'=>$dimensions[0], 'height'=>$dimensions[1],
            'bytes'=>filesize($preview), 'previewSHA256'=>hash_file('sha256',$preview),
            'attachedSHA256'=>hash_file('sha256',$full), 'metadataSHA256'=>hash('sha256',$image['metadata'])];
    }
}
if (count($checks) !== 6) { $issues[] = 'must_validate_all_six_images'; }
echo json_encode(['mode'=>'read-only-dry-run', 'selection'=>$wanted, 'images'=>$checks,
    'ready'=>$issues === [], 'issues'=>array_values(array_unique($issues))], JSON_UNESCAPED_SLASHES), "\n";
"""


def main():
    if sys.argv[1:] not in ([], ["--dry-run"]):
        raise SystemExit("Only --dry-run is supported; this checker never publishes.")
    query = shlex.join(["sudo", "-n", "-u", "www-data", "wp", f"--path={SITE}",
                        "db", "query", SQL, "--skip-column-names", "--batch", "--raw"])
    command = query + " | /usr/bin/php -r " + shlex.quote(REMOTE_CHECK)
    result = subprocess.run([WRAPPER, "primary", command], capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise SystemExit("Read-only server preflight failed; nothing was changed.")
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise SystemExit("Invalid preflight report; nothing was changed.") from None
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report.get("ready") is True else 2)


if __name__ == "__main__":
    main()
