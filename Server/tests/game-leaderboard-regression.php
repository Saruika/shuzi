<?php
declare(strict_types=1);

// No database, server bootstrap, user files, network, or real account is used.
// Executes the shipped rules, approved-fan gate, schema checks and route handlers.
define('ABSPATH', __DIR__ . '/');
define('ARRAY_A', 'ARRAY_A');
define('MINUTE_IN_SECONDS', 60);
final class WP_Error {
    public function __construct(public string $code, public string $message, public array $data = array()) {}
}
final class WP_User { public function __construct(public int $ID, public string $display_name) {} }
final class WP_REST_Request {
    public int $bodyReads = 0;
    public function __construct(public string $body = '', public string $authorization = 'Bearer synthetic') {}
    public function get_body(): string { ++$this->bodyReads; return $this->body; }
    public function get_header(string $key): string { return $key === 'authorization' ? $this->authorization : ''; }
}
final class WP_REST_Response {
    public array $headers = array();
    public function __construct(public array $data) {}
    public function header(string $key, string $value): void { $this->headers[$key] = $value; }
}
function is_wp_error($value): bool { return $value instanceof WP_Error; }
function rest_ensure_response(array $value): WP_REST_Response { return new WP_REST_Response($value); }
function sanitize_text_field(string $value): string { return trim(strip_tags($value)); }
function get_user_meta(int $id, string $key, bool $single) { return $GLOBALS['meta'][$id][$key] ?? ''; }
function get_userdata(int $id) { return $GLOBALS['users'][$id] ?? false; }
function get_option(string $key, $default = null) { return $GLOBALS['options'][$key] ?? $default; }
function update_option(string $key, $value, bool $autoload): bool { $GLOBALS['options'][$key] = $value; return true; }
function dbDelta($sql): array {
    $GLOBALS['wpdb']->ddl++;
    $GLOBALS['wpdb']->exists = true;
    return array();
}

final class GamePreparedQuery {
    public function __construct(public string $sql, public array $args) {}
}
final class GameFakeDatabase {
    public string $prefix = 'fixture_';
    public string $users = 'fixture_users';
    public string $usermeta = 'fixture_usermeta';
    public string $last_error = '';
    public bool $exists = true;
    public string $engine = 'InnoDB';
    public bool $badIndex = false;
    public bool $fail = false;
    public int $ddl = 0;
    public int $writes = 0;
    public int $leaderboardReads = 0;
    public int $lastProjectionSize = 0;
    public ?Closure $afterLeaderboardSnapshot = null;
    public array $rows = array();
    public array $queries = array();
    public function prepare(string $sql, ...$args): GamePreparedQuery {
        if (count($args) === 1 && is_array($args[0])) { $args = $args[0]; }
        preg_match_all('/%[isd]/', $sql, $matches);
        expect_game(count($matches[0]) === count($args), 'SQL placeholders match arguments');
        return new GamePreparedQuery($sql, $args);
    }
    public function esc_like(string $value): string { return addcslashes($value, '_%\\'); }
    public function get_charset_collate(): string { return 'DEFAULT CHARACTER SET utf8mb4'; }
    private function enter(GamePreparedQuery $query): bool {
        $this->queries[] = $query->sql;
        $this->last_error = $this->fail ? 'synthetic database failure' : '';
        return !$this->fail;
    }
    private function visible(): array {
        $rows = array_values(array_filter($this->rows, static fn($row) =>
            isset($GLOBALS['users'][$row['fan_user_id']])
            && ($GLOBALS['meta'][$row['fan_user_id']]['status'] ?? '') === 'active'
            && ($GLOBALS['meta'][$row['fan_user_id']]['uuid'] ?? '') !== ''
            && $row['rules_version'] === 'life-v1'));
        foreach ($rows as &$row) { $row['display_name'] = $GLOBALS['users'][$row['fan_user_id']]->display_name; }
        unset($row);
        usort($rows, static fn($a, $b) => ($b['score'] <=> $a['score'])
            ?: strcmp($a['achieved_at'], $b['achieved_at']) ?: ($a['fan_user_id'] <=> $b['fan_user_id']));
        return $rows;
    }
    public function get_results(GamePreparedQuery $query, string $format): ?array {
        if (!$this->enter($query)) { return null; }
        if (str_starts_with($query->sql, 'SHOW COLUMNS')) {
            return array_map(static fn($name, $type) => array('Field' => $name, 'Type' => $type, 'Null' => 'NO'),
                array('fan_user_id', 'rules_version', 'score', 'ending_id', 'origin', 'answered', 'achieved_at'),
                array('bigint unsigned', 'varchar(32)', 'int', 'varchar(64)', 'varchar(32)', 'smallint unsigned', 'datetime'));
        }
        if (str_starts_with($query->sql, 'SHOW INDEX')) {
            $rows = array(array('Key_name' => 'PRIMARY', 'Seq_in_index' => 1, 'Column_name' => 'fan_user_id', 'Non_unique' => 0, 'Sub_part' => null));
            foreach (array('score', 'achieved_at', 'fan_user_id') as $index => $column) {
                if ($this->badIndex && $index === 2) { continue; }
                $rows[] = array('Key_name' => 'score_time_user', 'Seq_in_index' => $index + 1, 'Column_name' => $column, 'Non_unique' => 1, 'Sub_part' => null);
            }
            return $rows;
        }
        // This fake checks the query contract and models one statement's read
        // snapshot; it is not a SQL parser or a real MySQL concurrency test.
        $sql = preg_replace('/\s+/', ' ', $query->sql);
        $columns = 'b.fan_user_id, b.rules_version, b.score, b.ending_id, b.origin, b.answered, b.achieved_at, u.display_name';
        expect_game(str_starts_with($sql, 'SELECT candidate.fan_user_id, candidate.rules_version, candidate.score, candidate.ending_id, candidate.origin, candidate.answered, candidate.achieved_at, candidate.display_name, ')
            && substr_count($sql, 'SELECT ' . $columns . ' FROM %i b') === 2,
            'both UNION arms have the same explicit summary/name projection');
        expect_game(str_contains($sql, 'FROM ((SELECT ' . $columns)
            && str_contains($sql, 'ORDER BY b.score DESC, b.achieved_at ASC, b.fan_user_id ASC LIMIT %d) UNION (SELECT ' . $columns)
            && str_contains($sql, 'AND b.fan_user_id = %d LIMIT 1)) AS candidate')
            && str_ends_with($sql, 'ORDER BY candidate.score DESC, candidate.achieved_at ASC, candidate.fan_user_id ASC LIMIT %d'),
            'deduplicating UNION has arm-local top limit, own filter, and stable bounded outer order');
        expect_game(str_contains($sql, 'CASE WHEN candidate.fan_user_id = %d THEN (SELECT COUNT(*)')
            && str_contains($sql, 'AND (b.score > candidate.score OR (b.score = candidate.score AND (b.achieved_at < candidate.achieved_at OR (b.achieved_at = candidate.achieved_at AND b.fan_user_id < candidate.fan_user_id))))) + 1 ELSE 0 END AS own_rank'),
            'own rank is correlated to the candidate with exact score/time/id ordering');
        foreach (array('INNER JOIN %i u ON u.ID = b.fan_user_id', 'WHERE b.rules_version = %s',
            'AND EXISTS (SELECT 1 FROM %i s WHERE s.user_id = b.fan_user_id AND s.meta_key = %s AND s.meta_value = %s)',
            'AND EXISTS (SELECT 1 FROM %i f WHERE f.user_id = b.fan_user_id AND f.meta_key = %s AND f.meta_value <> %s)') as $filter) {
            expect_game(substr_count($sql, $filter) === 3, 'top/own/count use identical visible filters');
        }
        $visible_args = array($this->prefix . 'yishu_game_leaderboard', $this->users, 'life-v1',
            $this->usermeta, 'status', 'active', $this->usermeta, 'uuid', '');
        $user_id = $query->args[0];
        expect_game(count($query->args) === 31
            && array_slice($query->args, 1, 9) === $visible_args
            && array_slice($query->args, 10, 9) === $visible_args
            && array_slice($query->args, 20, 9) === $visible_args
            && $query->args[19] === 100 && $query->args[29] === $user_id && $query->args[30] === 101,
            'every repeated identifier/filter and both bounds are prepared in placeholder order');
        expect_game(!preg_match('/UNION ALL|SELECT b\.\*|ROW_NUMBER|OVER\s*\(|FOR UPDATE|LOCK IN SHARE MODE|START TRANSACTION|SET TRANSACTION/i', $sql),
            'snapshot projection requires no duplicate arm, wildcard, window function, lock, or transaction change');
        ++$this->leaderboardReads;
        $snapshot = $this->visible();
        if ($this->afterLeaderboardSnapshot !== null) {
            $callback = $this->afterLeaderboardSnapshot;
            $this->afterLeaderboardSnapshot = null;
            $callback($this);
        }
        $result = array();
        foreach ($snapshot as $index => $row) {
            if ($index < 100 || $row['fan_user_id'] === $user_id) {
                $row['own_rank'] = $row['fan_user_id'] === $user_id ? $index + 1 : 0;
                $result[] = $row;
            }
        }
        $this->lastProjectionSize = count($result);
        expect_game(count($result) <= 101, 'fake statement emits at most top100 plus one own row');
        return $result;
    }
    public function get_row(GamePreparedQuery $query, string $format): ?array {
        if (!$this->enter($query)) { return null; }
        if (str_starts_with($query->sql, 'SHOW TABLE STATUS')) {
            return $this->exists ? array('Name' => $this->prefix . 'yishu_game_leaderboard', 'Engine' => $this->engine) : null;
        }
        if (str_starts_with($query->sql, 'SELECT score, rules_version')) {
            return $this->rows[$query->args[1]] ?? null;
        }
        expect_game(false, 'no separate own-row read may mix leaderboard snapshots');
        return null;
    }
    public function get_var(GamePreparedQuery $query) {
        if (!$this->enter($query)) { return null; }
        if (str_starts_with($query->sql, 'SHOW TABLES')) { return $this->exists ? $this->prefix . 'yishu_game_leaderboard' : null; }
        if (str_starts_with($query->sql, 'SELECT ID')) { return isset($GLOBALS['users'][$query->args[1]]) ? $query->args[1] : null; }
        expect_game(false, 'no separate rank-count read may mix leaderboard snapshots');
        return null;
    }
    public function query(GamePreparedQuery $query) {
        if (!$this->enter($query)) { return false; }
        $a = $query->args;
        $this->writes++;
        if (str_starts_with($query->sql, 'INSERT')) {
            expect_game(!isset($this->rows[$a[1]]), 'one primary-key row');
            $this->rows[$a[1]] = array('fan_user_id' => $a[1], 'rules_version' => $a[2], 'score' => $a[3],
                'ending_id' => $a[4], 'origin' => $a[5], 'answered' => $a[6], 'achieved_at' => $a[7]);
            return 1;
        }
        if (str_starts_with($query->sql, 'UPDATE')) {
            expect_game($this->rows[$a[6]]['score'] < $a[8], 'only a strictly higher score updates');
            $this->rows[$a[6]] = array('fan_user_id' => $a[6], 'rules_version' => $a[7], 'score' => $a[1],
                'ending_id' => $a[2], 'origin' => $a[3], 'answered' => $a[4], 'achieved_at' => $a[5]);
            return 1;
        }
        expect_game(str_starts_with($query->sql, 'DELETE FROM %i WHERE fan_user_id = %d'), 'delete only authenticated user');
        $had = isset($this->rows[$a[1]]);
        unset($this->rows[$a[1]]);
        return $had ? 1 : 0;
    }
}

require dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-game-rules.php';
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-fan-endpoints.php';
require dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-game-leaderboard.php';
final class GameHarness {
    use Shuzijun_App_Fan_Endpoints;
    use Shuzijun_App_Game_Leaderboard;
    const FAN_META_STATUS = 'status';
    const FAN_META_UUID = 'uuid';
    const FAN_META_INVITATION = 'invitation';
    const FAN_META_PASSWORD_RECOVERY = 'recovery';
    const FAN_META_APPLE_SETUP = 'apple_setup';
    const GAME_SCHEMA_OPTION = 'game_schema';
    const GAME_SCHEMA_VERSION = 1;
    private static $fan_session_context = null;
    public static function account_authority_enabled(): bool { return $GLOBALS['authority']; }
    private static function authenticate_fan_session(WP_REST_Request $request) {
        if ($request->authorization !== 'Bearer synthetic') { return new WP_Error('unauthorized', '', array('status' => 401)); }
        return $GLOBALS['context'];
    }
    private static function fan_session_context_is_current_from_database($context, $scope): bool {
        expect_game($GLOBALS['locked'], 'fresh session check is under user lock');
        return $GLOBALS['fresh'] && $context['scope'] === $scope;
    }
    private static function fan_meta_from_database($id, $key, $default) { return $GLOBALS['meta'][$id][$key] ?? $default; }
    private static function fan_has_required_douyin_id($id): bool { return $GLOBALS['meta'][$id]['complete'] ?? false; }
    private static function fan_permissions_for_user($id): array { return array(); }
    private static function rate_limit($bucket, $id, $limit, $window) {
        expect_game($id === (string) $GLOBALS['context']['userID'], 'rate limit authenticated actor');
        expect_game(in_array($bucket, array('game_read', 'game_submit', 'game_delete'), true)
            && $window === 60 && $limit === ($bucket === 'game_read' ? 60 : 12), 'exact operation budget');
        $key = $bucket . '|' . $id;
        $GLOBALS['rateCalls'][$key] = ($GLOBALS['rateCalls'][$key] ?? 0) + 1;
        $count = $GLOBALS['rateCounts'][$key] ?? 0;
        if ($GLOBALS['rateLimited'] || $count >= $limit) {
            return new WP_Error('rate', '', array('status' => 429));
        }
        $GLOBALS['rateCounts'][$key] = $count + 1;
        return true;
    }
    private static function acquire_fan_lock($id) {
        if ($GLOBALS['locked']) { return new WP_Error('busy', '', array('status' => 409)); }
        $GLOBALS['locked'] = true;
        if (is_callable($GLOBALS['afterLock'] ?? null)) { ($GLOBALS['afterLock'])(); }
        return 'synthetic-lock';
    }
    private static function release_fan_lock($id, $lock): void { $GLOBALS['locked'] = false; }
    private static function acquire_named_fan_lock($scope, $name) { return 'synthetic-schema-lock'; }
    private static function release_named_fan_lock($lock): void {}
}

$checks = 0;
function expect_game(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException($label); }
    ++$GLOBALS['checks'];
}
function reset_game(): void {
    $GLOBALS['wpdb'] = new GameFakeDatabase();
    $GLOBALS['context'] = array('userID' => 17, 'scope' => 'normal');
    $GLOBALS['users'] = array(17 => new WP_User(17, '合成玩家'));
    $GLOBALS['meta'] = array(17 => array('status' => 'active', 'uuid' => 'synthetic-id', 'complete' => true));
    $GLOBALS['options'] = array();
    $GLOBALS['authority'] = true;
    $GLOBALS['fresh'] = true;
    $GLOBALS['locked'] = false;
    $GLOBALS['rateLimited'] = false;
    $GLOBALS['rateCalls'] = array();
    $GLOBALS['rateCounts'] = array();
    $GLOBALS['afterLock'] = null;
}
function dispatch_game(string $method, ?array $body = null, string $authorization = 'Bearer synthetic') {
    $request = new WP_REST_Request($body === null ? '' : json_encode($body, JSON_THROW_ON_ERROR), $authorization);
    return dispatch_game_request($method, $request);
}
function dispatch_game_request(string $method, WP_REST_Request $request) {
    $permission = GameHarness::can_access_game_leaderboard($request);
    if ($permission !== true) { return $permission; }
    return match ($method) {
        'GET' => GameHarness::get_game_leaderboard($request),
        'POST' => GameHarness::submit_game_score($request),
        'DELETE' => GameHarness::delete_game_score($request),
    };
}
function expect_status($value, int $status, string $label): void {
    expect_game($value instanceof WP_Error && ($value->data['status'] ?? 0) === $status, $label);
}
$full = array_fill(0, 108, 0); $full[2] = 1;
$early = array_merge(array_fill(0, 20, 3), array_fill(0, 42, 2));
$payload = array('rulesVersion' => 'life-v1', 'origin' => 'business', 'choices' => $full, 'consent' => true);

reset_game();
$bundled_path = dirname(__DIR__) . '/vendor/shuzijun/app-content/game-rules-v1.json';
expect_game(is_file($bundled_path) && !is_link($bundled_path)
    && hash_file('sha256', $bundled_path) === Shuzijun_Game_Rules::FILE_SHA256, 'rules bundled beside loader with reviewed hash');
$rules = Shuzijun_Game_Rules::bundled();
expect_game($rules->hash() === json_decode(file_get_contents($bundled_path), true, 32, JSON_THROW_ON_ERROR)['rulesHash'],
    'real bundled loader uses shipped rules');
foreach (array('peasant' => 12966, 'worker' => 12966, 'teacher' => 12981, 'official' => 12966, 'business' => 12966, 'soldier' => 12996) as $origin => $score) {
    $result = $rules->replay($origin, $full);
    expect_game($result['score'] === $score && $result['endingID'] === 'top_human' && $result['answered'] === 108, 'six-origin complete vector');
}
$fatal = $rules->replay('business', $early);
expect_game($fatal['score'] === -214 && $fatal['endingID'] === 'fall_death'
    && $fatal['answered'] === 62 && $fatal['totalAnswered'] === 61, 'negative original score and fatal choice retained');
foreach (array(array(), array(0), array(true), array(0.0), array('0'), array(4), array_fill(0, 109, 0),
    array_merge($early, array(0)), array_slice($early, 0, 61)) as $bad) {
    try { $rules->replay('business', $bad); expect_game(false, 'invalid sequence accepted'); }
    catch (InvalidArgumentException $error) { expect_game(true, 'invalid sequence rejected'); }
}

foreach (array('pending', 'rejected', 'suspended', '') as $status) {
    reset_game(); $GLOBALS['meta'][17]['status'] = $status;
    foreach (array('GET', 'POST', 'DELETE') as $method) { expect_status(dispatch_game($method, $method === 'POST' ? $payload : null), 403, 'only approved status'); }
}
foreach (array('onboarding', 'password_recovery', 'apple_onboarding') as $scope) {
    reset_game(); $GLOBALS['context']['scope'] = $scope;
    expect_status(dispatch_game('POST', $payload), 403, 'temporary scope excluded');
}
foreach (array('invitation', 'recovery', 'apple_setup') as $marker) {
    reset_game(); $GLOBALS['meta'][17][$marker] = array('active' => true);
    expect_status(dispatch_game('GET'), 403, 'incomplete account excluded');
}

// An unapproved/unauthenticated caller must not read even a malformed body or
// spend another actor's budget; approved invalid requests do spend their own.
foreach (array('POST', 'DELETE') as $method) {
    reset_game();
    $request = new WP_REST_Request('{malformed', 'Basic synthetic');
    expect_status(dispatch_game_request($method, $request), 401, 'authentication precedes body parsing');
    expect_game($request->bodyReads === 0 && $GLOBALS['rateCalls'] === array(), 'unauthenticated body and budget untouched');
    $GLOBALS['meta'][17]['status'] = 'pending';
    $request = new WP_REST_Request('{malformed');
    expect_status(dispatch_game_request($method, $request), 403, 'approval precedes body parsing');
    expect_game($request->bodyReads === 0 && $GLOBALS['rateCalls'] === array(), 'unapproved body and budget untouched');
}
reset_game();
$numeric_object_body = json_encode(array_replace($payload, array('choices' => (object) $full)), JSON_THROW_ON_ERROR);
expect_game(json_decode($numeric_object_body)->choices instanceof stdClass
    && count(get_object_vars(json_decode($numeric_object_body)->choices)) === 108,
    'negative fixture is a complete 108-option JSON object, not an array');
expect_status(dispatch_game_request('POST', new WP_REST_Request($numeric_object_body)), 400,
    'numeric-key JSON object cannot masquerade as a complete array trace');
expect_game($GLOBALS['wpdb']->writes === 0 && $GLOBALS['rateCounts']['game_submit|17'] === 1,
    'wrong JSON trace shape is charged once and stores nothing');
expect_game(dispatch_game('POST', $payload) instanceof WP_REST_Response,
    'the identical 108 choices encoded as a JSON array remain valid');
$invalid_submissions = array(
    array('', 400), array('{malformed', 400), array('[]', 400), array('{}', 400),
    array(json_encode(array_replace($payload, array('consent' => false)), JSON_THROW_ON_ERROR), 400),
    array(json_encode(array_replace($payload, array('score' => 999999)), JSON_THROW_ON_ERROR), 400),
    array($numeric_object_body, 400),
    array(str_repeat(' ', 4097), 413),
);
foreach (array('POST' => $invalid_submissions, 'DELETE' => array(array('{malformed', 400), array('{"userID":1}', 400))) as $method => $cases) {
    foreach ($cases as [$body, $status]) {
        reset_game();
        $request = new WP_REST_Request($body);
        $key = ($method === 'POST' ? 'game_submit' : 'game_delete') . '|17';
        for ($attempt = 1; $attempt <= 12; ++$attempt) {
            expect_status(dispatch_game_request($method, $request), $status, 'invalid authenticated request consumes budget');
            expect_game($GLOBALS['rateCalls'][$key] === $attempt && $GLOBALS['rateCounts'][$key] === $attempt,
                'one budget charge per invalid request');
        }
        expect_status(dispatch_game_request($method, $request), 429, 'thirteenth invalid request is limited');
        expect_game($request->bodyReads === 12 && $GLOBALS['rateCalls'][$key] === 13
            && $GLOBALS['rateCounts'][$key] === 12 && $GLOBALS['wpdb']->writes === 0
            && !$GLOBALS['locked'], 'limited request does not read body, write score, or retain lock');
        expect_game(dispatch_game('GET') instanceof WP_REST_Response, 'write budget does not consume read budget');
    }
}
reset_game();
expect_status(dispatch_game('POST', $payload, 'Basic synthetic'), 401, 'legacy manager is not leaderboard user');
$GLOBALS['authority'] = false;
expect_status(dispatch_game('GET'), 503, 'standby denies leaderboard');
reset_game(); $GLOBALS['wpdb']->exists = false;
expect_status(dispatch_game('GET'), 503, 'missing table does not install on GET');
expect_game($GLOBALS['wpdb']->ddl === 0, 'GET executes no DDL');
expect_game(GameHarness::ensure_game_leaderboard_storage(), 'explicit CLI installer verifies schema');
expect_game($GLOBALS['wpdb']->ddl === 1, 'explicit installer creates once');
expect_game(GameHarness::ensure_game_leaderboard_storage() && $GLOBALS['wpdb']->ddl === 1, 'installer idempotent');
$GLOBALS['wpdb']->engine = 'MyISAM';
expect_status(dispatch_game('GET'), 503, 'wrong engine fails closed');
$GLOBALS['wpdb']->engine = 'InnoDB'; $GLOBALS['wpdb']->badIndex = true;
expect_status(dispatch_game('GET'), 503, 'missing rank index fails closed');

reset_game();
foreach (array(array_replace($payload, array('consent' => false)),
    array_replace($payload, array('consent' => 'true')), array_replace($payload, array('rulesVersion' => 'wrong')),
    array_replace($payload, array('origin' => 'unknown')), array_replace($payload, array('score' => 999999)),
    array_replace($payload, array('userID' => 1)), array_replace($payload, array('choices' => array(true)))) as $bad) {
    expect_status(dispatch_game('POST', $bad), 400, 'strict submission and no client identity/score');
}
expect_game($GLOBALS['wpdb']->writes === 0, 'bad payloads store nothing');
$lower = array_replace($payload, array('choices' => $early));
$first = dispatch_game('POST', $lower);
expect_game($first instanceof WP_REST_Response && $first->data['myEntry']['score'] === -214, 'negative valid submission accepted');
$high = dispatch_game('POST', $payload);
expect_game($high instanceof WP_REST_Response && $high->data['myEntry']['score'] === 12966, 'higher result replaces');
$saved = $GLOBALS['wpdb']->rows[17]; $writes = $GLOBALS['wpdb']->writes;
dispatch_game('POST', $payload); dispatch_game('POST', $lower);
expect_game($GLOBALS['wpdb']->rows[17] === $saved && $GLOBALS['wpdb']->writes === $writes, 'ties and lower scores never overwrite time or result');
expect_game($GLOBALS['rateCalls']['game_submit|17'] === 11
    && $GLOBALS['rateCounts']['game_submit|17'] === 11, 'valid submission and retries each charge only once');
expect_game(array_keys($saved) === array('fan_user_id', 'rules_version', 'score', 'ending_id', 'origin', 'answered', 'achieved_at'), 'only one summary without choices or nickname');
$GLOBALS['users'][17]->display_name = '当前昵称';
$read = dispatch_game('GET');
expect_game($read->data['myEntry']['displayName'] === '当前昵称', 'current name, not snapshot');
$entryKeys = array('rank', 'displayName', 'score', 'endingTitle', 'originName', 'answered', 'achievedAt', 'isMe');
expect_game(array_keys($read->data['myEntry']) === $entryKeys, 'public response excludes all identifiers and credentials');
expect_game(($read->headers['Cache-Control'] ?? '') === 'private, no-store, max-age=0'
    && ($read->headers['Vary'] ?? '') === 'Authorization, X-Yishu-Install-ID', 'private response cache boundaries');
expect_status(dispatch_game('DELETE', array('userID' => 1)), 400, 'cannot select another deletion owner');
$deleted = dispatch_game('DELETE');
expect_game($deleted->data['myEntry'] === null && count($GLOBALS['wpdb']->rows) === 0, 'withdraw own score');
expect_game(dispatch_game('DELETE')->data['myEntry'] === null, 'withdraw idempotent');
expect_game($GLOBALS['rateCalls']['game_delete|17'] === 3
    && $GLOBALS['rateCounts']['game_delete|17'] === 3, 'valid and invalid withdrawals each charge only once');

reset_game(); dispatch_game('POST', $payload);
$saved = $GLOBALS['wpdb']->rows[17];
foreach (array('HS-ABCD-2345', 'hs-abcd-2345', 'IN-ABC-234',
    '00000000-0000-4000-8000-000000000001', str_repeat('a', 32),
    'fan_' . str_repeat('a', 32), 'fan_apple_' . str_repeat('b', 32),
    '受邀粉丝 ABCD', 'fixture@example.invalid', str_repeat('a', 48) . '@example.invalid', '') as $name) {
    $GLOBALS['users'][17]->display_name = $name;
    $response = dispatch_game('GET');
    expect_game($response instanceof WP_REST_Response
        && $response->data['entries'][0]['displayName'] === '玩家'
        && $response->data['myEntry']['displayName'] === '玩家', 'system identity fallback is never public');
}
foreach (array('狐狸不熬夜', 'Alice', 'HS队长', 'UUID 爱好者', '小梳子🙂', '花·夏', 'fan_club') as $name) {
    $GLOBALS['users'][17]->display_name = $name;
    $response = dispatch_game('GET');
    expect_game($response instanceof WP_REST_Response
        && $response->data['myEntry']['displayName'] === $name, 'ordinary nicknames remain unchanged');
}
expect_game($GLOBALS['wpdb']->rows[17] === $saved, 'nickname privacy projection never mutates stored account or score');

foreach (array('revoked', 'suspended', 'deleted') as $change) {
    reset_game();
    $GLOBALS['afterLock'] = static function () use ($change): void {
        if ($change === 'revoked') { $GLOBALS['fresh'] = false; }
        if ($change === 'suspended') { $GLOBALS['meta'][17]['status'] = 'suspended'; }
        if ($change === 'deleted') { unset($GLOBALS['users'][17]); }
    };
    expect_status(dispatch_game('POST', $payload), 403, 'fresh check rejects concurrent account transition');
    expect_game(!$GLOBALS['locked'] && $GLOBALS['wpdb']->writes === 0, 'no resurrection and lock released');
}
reset_game(); $GLOBALS['locked'] = true;
expect_status(dispatch_game('POST', $payload), 409, 'account deletion lock excludes submission');
reset_game(); $GLOBALS['rateLimited'] = true;
expect_status(dispatch_game('POST', $payload), 429, 'submission rate limited');

reset_game(); dispatch_game('POST', $payload);
for ($id = 100; $id < 207; $id++) {
    $GLOBALS['users'][$id] = new WP_User($id, '合成榜员 ' . $id);
    $GLOBALS['meta'][$id] = array('status' => 'active', 'uuid' => 'synthetic-' . $id, 'complete' => true);
    $GLOBALS['wpdb']->rows[$id] = array_replace($GLOBALS['wpdb']->rows[17], array('fan_user_id' => $id, 'score' => 14000, 'achieved_at' => '2026-01-01 00:00:00'));
}
$GLOBALS['meta'][100]['status'] = 'suspended'; unset($GLOBALS['users'][101]);
$ranked = dispatch_game('GET');
expect_game(count($ranked->data['entries']) === 100 && $ranked->data['myEntry']['rank'] === 106, 'top 100 plus own rank excludes inactive/deleted');
expect_game($ranked->data['entries'][0]['displayName'] === '合成榜员 102', 'deterministic equal-score time/user tie');
expect_game(count(array_filter($ranked->data['entries'], static fn($e) => $e['isMe'])) === 0, 'self outside first page only in myEntry');
expect_game($GLOBALS['wpdb']->lastProjectionSize === 101, 'own row outside top100 makes exactly one extra candidate');
$GLOBALS['wpdb']->fail = true;
expect_game(!GameHarness::purge_game_leaderboard_for_fan_user(17), 'database failure cannot acknowledge account purge');
$GLOBALS['wpdb']->fail = false; $GLOBALS['wpdb']->exists = false;
expect_game(GameHarness::purge_game_leaderboard_for_fan_user(17), 'old installation without table permits account deletion');

// Reproduce the old list/own/count race deterministically: the actor is rank101
// when the statement begins, then a higher peer withdraws or is suspended. A
// split-query implementation produced myEntry.rank100 beside another rank100.
// The current statement must return its one snapshot, and the next read must
// reflect the peer transition. No real database or transaction is simulated.
foreach (array('withdrawal', 'suspension') as $transition) {
    reset_game(); dispatch_game('POST', $payload);
    for ($id = 199; $id >= 100; --$id) {
        $GLOBALS['users'][$id] = new WP_User($id, '合成榜员 ' . $id);
        $GLOBALS['meta'][$id] = array('status' => 'active', 'uuid' => 'synthetic-' . $id, 'complete' => true);
        $GLOBALS['wpdb']->rows[$id] = array_replace($GLOBALS['wpdb']->rows[17], array(
            'fan_user_id' => $id, 'score' => 14000, 'achieved_at' => '2026-01-01 00:00:00'));
    }
    $db = $GLOBALS['wpdb'];
    $reads = $db->leaderboardReads;
    $mutated = false;
    $db->afterLeaderboardSnapshot = static function (GameFakeDatabase $database) use ($transition, &$mutated): void {
        if ($transition === 'withdrawal') { unset($database->rows[100]); }
        else { $GLOBALS['meta'][100]['status'] = 'suspended'; }
        $mutated = true;
    };
    $before = dispatch_game('GET');
    expect_game($mutated && $before instanceof WP_REST_Response
        && $db->leaderboardReads === $reads + 1 && $db->lastProjectionSize === 101,
        'concurrent peer transition occurs during exactly one bounded projection read');
    expect_game(count($before->data['entries']) === 100 && $before->data['myEntry']['rank'] === 101
        && $before->data['entries'][0]['displayName'] === '合成榜员 100'
        && $before->data['entries'][99]['rank'] === 100 && !$before->data['entries'][99]['isMe']
        && count(array_filter($before->data['entries'], static fn($entry) => $entry['isMe'])) === 0,
        'current response retains one coherent pre-transition list and own rank');
    $after = dispatch_game('GET');
    expect_game($after instanceof WP_REST_Response && $db->leaderboardReads === $reads + 2
        && $db->lastProjectionSize === 100 && count($after->data['entries']) === 100,
        'next response uses one fresh projection with no duplicate own candidate');
    expect_game($after->data['myEntry']['rank'] === 100
        && $after->data['entries'][0]['displayName'] === '合成榜员 101'
        && $after->data['entries'][99] === $after->data['myEntry']
        && count(array_filter($after->data['entries'], static fn($entry) => $entry['isMe'])) === 1,
        'next response reflects withdrawal/suspension and identical in-page own entry');
}

// Equal scores sort by achievement time before user ID, independently of row
// insertion order. UNION emits the own row once when it is already in top100.
reset_game(); dispatch_game('POST', $payload);
$GLOBALS['wpdb']->rows[17]['achieved_at'] = '2026-01-01 00:00:00';
for ($id = 204; $id >= 100; --$id) {
    $GLOBALS['users'][$id] = new WP_User($id, '合成榜员 ' . $id);
    $GLOBALS['meta'][$id] = array('status' => 'active', 'uuid' => 'synthetic-' . $id, 'complete' => true);
    $GLOBALS['wpdb']->rows[$id] = array_replace($GLOBALS['wpdb']->rows[17], array('fan_user_id' => $id));
}
$tie = dispatch_game('GET');
expect_game($tie->data['myEntry']['rank'] === 1 && $tie->data['entries'][0] === $tie->data['myEntry']
    && $tie->data['entries'][1]['displayName'] === '合成榜员 100'
    && count(array_filter($tie->data['entries'], static fn($entry) => $entry['isMe'])) === 1
    && $GLOBALS['wpdb']->lastProjectionSize === 100, 'equal-score equal-time ID order and own deduplication');
$GLOBALS['wpdb']->rows[17]['achieved_at'] = '2026-01-02 00:00:00';
$later = dispatch_game('GET');
expect_game($later->data['myEntry']['rank'] === 106 && $later->data['entries'][0]['displayName'] === '合成榜员 100'
    && $GLOBALS['wpdb']->lastProjectionSize === 101, 'earlier achievement outranks lower user ID on equal score');
unset($GLOBALS['wpdb']->rows[17]);
$absent = dispatch_game('GET');
expect_game($absent->data['myEntry'] === null && count($absent->data['entries']) === 100
    && $GLOBALS['wpdb']->lastProjectionSize === 100
    && count(array_filter($absent->data['entries'], static fn($entry) => $entry['isMe'])) === 0,
    'no own record means bounded top100 only and null myEntry');
reset_game();
$empty = dispatch_game('GET');
expect_game($empty->data['entries'] === array() && $empty->data['myEntry'] === null
    && $GLOBALS['wpdb']->lastProjectionSize === 0 && $GLOBALS['wpdb']->leaderboardReads === 1,
    'empty leaderboard is one empty projection with no fabricated own entry');

$source = file_get_contents(dirname(__DIR__) . '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php');
expect_game(str_contains($source, "'/fan/game/leaderboard'") && str_contains($source, "'/fan/game/scores'")
    && substr_count($source, "'permission_callback' => array(__CLASS__, 'can_access_game_leaderboard')") === 3, 'three authenticated routes registered');
expect_game(str_contains($source, "add_action('yishu_install_game_leaderboard_storage'")
    && !str_contains($source, "add_action('init', array(__CLASS__, 'ensure_game_leaderboard_storage')"), 'explicit deployment hook, no init DDL');
$identity = file_get_contents(dirname(__DIR__) . '/vendor/shuzijun/app-content/trait-shuzijun-app-fan-identity.php');
expect_game(substr_count($identity, 'self::purge_game_leaderboard_for_fan_user($user_id)') === 2, 'App and WordPress deletion both purge');
$hook = substr($identity, strpos($identity, 'public static function prepare_fan_user_deletion'));
expect_game(strpos($hook, 'self::purge_game_leaderboard_for_fan_user') < strpos($hook, 'if (!get_user_meta($user_id, self::FAN_META_UUID, true))'), 'core deletion purges even missing fan UUID');
echo "game-leaderboard-regression: {$checks} assertions passed (fake WP/DB; real MySQL concurrency not covered)\n";
