<?php

defined('ABSPATH') || exit;

trait Shuzijun_App_Collaboration {
    public static function ensure_collaboration_storage() {
        if (!self::collaboration_phase1_enabled()
            || !self::account_authority_enabled()) { return false; }
        if ((int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                === self::COLLABORATION_SCHEMA_VERSION
            && self::collaboration_tables_exist()) {
            return true;
        }

        $lock = self::acquire_named_fan_lock('collab_schema', 'version-1');
        if (is_wp_error($lock)) {
            do_action('yishu_collaboration_security_audit', 'schema_lock_unavailable');
            return false;
        }
        try {
            if ((int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                    === self::COLLABORATION_SCHEMA_VERSION
                && self::collaboration_tables_exist()) {
                return true;
            }

            global $wpdb;
            if (!isset($wpdb) || !method_exists($wpdb, 'get_charset_collate')) { return false; }
            if (!function_exists('dbDelta')) {
                require_once ABSPATH . 'wp-admin/includes/upgrade.php';
            }
            if (!function_exists('dbDelta')) { return false; }

            $tables = self::collaboration_tables();
            if (!$tables) { return false; }
            $charset = $wpdb->get_charset_collate();
            $requests_sql = "CREATE TABLE {$tables['requests']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                public_id char(36) NOT NULL,
                submission_id char(36) NOT NULL,
                fan_user_id bigint(20) unsigned NOT NULL,
                install_hash char(64) NOT NULL,
                network_hash char(64) NOT NULL,
                contact_name varchar(120) NOT NULL,
                contact_method varchar(255) NOT NULL,
                organization varchar(160) NOT NULL DEFAULT '',
                project_type varchar(40) NOT NULL,
                city varchar(120) NOT NULL DEFAULT '',
                preferred_date date NULL,
                budget varchar(120) NOT NULL DEFAULT '',
                details text NOT NULL,
                payload_hash char(64) NOT NULL,
                status varchar(24) NOT NULL DEFAULT 'received',
                status_updated_by bigint(20) unsigned NULL,
                version bigint(20) unsigned NOT NULL DEFAULT 1,
                created_at datetime NOT NULL,
                updated_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY public_id (public_id),
                UNIQUE KEY fan_submission (fan_user_id, submission_id),
                KEY status_created (status, created_at),
                KEY fan_created (fan_user_id, created_at)
            ) ENGINE=InnoDB {$charset};";
            $outbox_sql = "CREATE TABLE {$tables['outbox']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                request_id bigint(20) unsigned NOT NULL,
                channel varchar(32) NOT NULL,
                dedupe_key char(64) NOT NULL,
                status varchar(20) NOT NULL DEFAULT 'pending',
                attempts smallint(5) unsigned NOT NULL DEFAULT 0,
                next_attempt_at datetime NOT NULL,
                lease_token char(32) NULL,
                lease_until datetime NULL,
                last_error_code varchar(80) NOT NULL DEFAULT '',
                created_at datetime NOT NULL,
                updated_at datetime NOT NULL,
                PRIMARY KEY  (id),
                UNIQUE KEY dedupe_key (dedupe_key),
                KEY due_jobs (status, next_attempt_at),
                UNIQUE KEY request_channel (request_id, channel)
            ) ENGINE=InnoDB {$charset};";
            $audit_sql = "CREATE TABLE {$tables['audit']} (
                id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
                request_id bigint(20) unsigned NOT NULL,
                actor_type varchar(20) NOT NULL,
                actor_id bigint(20) unsigned NOT NULL DEFAULT 0,
                event varchar(64) NOT NULL,
                result varchar(32) NOT NULL,
                metadata_json text NOT NULL,
                created_at datetime NOT NULL,
                PRIMARY KEY  (id),
                KEY request_created (request_id, created_at),
                KEY event_created (event, created_at)
            ) ENGINE=InnoDB {$charset};";
            // dbDelta describes attempted changes; its return value is not a
            // transaction/schema guarantee. Check each call before another
            // query can clear last_error, then verify the actual metadata.
            foreach (array($requests_sql, $outbox_sql, $audit_sql) as $schema_sql) {
                $changes = dbDelta($schema_sql);
                if (!is_array($changes) || !empty($wpdb->last_error)) {
                    do_action('yishu_collaboration_security_audit', 'schema_creation_failed');
                    return false;
                }
                foreach ($changes as $change) {
                    if (!is_string($change)) {
                        do_action('yishu_collaboration_security_audit', 'schema_creation_failed');
                        return false;
                    }
                }
            }
            if (!self::collaboration_tables_exist()) {
                do_action('yishu_collaboration_security_audit', 'schema_creation_failed');
                return false;
            }
            $saved = update_option(
                self::COLLABORATION_SCHEMA_OPTION,
                self::COLLABORATION_SCHEMA_VERSION,
                false
            );
            return $saved
                || (int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                    === self::COLLABORATION_SCHEMA_VERSION;
        } catch (Throwable $error) {
            do_action('yishu_collaboration_security_audit', 'schema_creation_failed');
            return false;
        } finally {
            self::release_named_fan_lock($lock);
        }
    }

    public static function create_collaboration_request(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()) {
            return self::collaboration_feature_disabled_error();
        }
        $context = self::$fan_session_context;
        if (!is_array($context) || (int) ($context['userID'] ?? 0) <= 0
            || ($context['scope'] ?? '') !== 'normal') {
            return new WP_Error(
                'collaboration_fan_required',
                '请使用已批准的粉丝账号重新登录。',
                array('status' => 403)
            );
        }
        $input = self::sanitize_collaboration_submission($request);
        if (is_wp_error($input)) { return $input; }
        if (!self::collaboration_storage_ready()) {
            return self::collaboration_storage_error();
        }

        $fan_user_id = (int) $context['userID'];
        $fan_lock_owner = self::acquire_fan_lock($fan_user_id);
        if (is_wp_error($fan_lock_owner)) {
            return new WP_Error(
                'collaboration_submission_busy',
                '账号资料正在更新，请稍后重试邀约。',
                array('status' => 409)
            );
        }
        try {
        if (!self::collaboration_fan_context_is_current_from_database($context)) {
            return new WP_Error(
                'collaboration_fan_required',
                '账号资料、权限或登录状态已变更，请重新登录后提交。',
                array('status' => 403)
            );
        }
        $existing = self::find_collaboration_submission(
            $fan_user_id,
            (string) $input['submissionID']
        );
        if (is_wp_error($existing)) { return $existing; }
        if (is_array($existing)) {
            return self::collaboration_submission_response($existing, $input['payloadHash'], true);
        }

        $install_id = self::request_install_id($request);
        if (is_wp_error($install_id)) { return $install_id; }
        foreach (array(
            array('collaboration_user', (string) $fan_user_id, 12, HOUR_IN_SECONDS),
            array('collaboration_install', $install_id, 12, HOUR_IN_SECONDS),
            array('collaboration_net', self::request_network_fingerprint(), 30, HOUR_IN_SECONDS),
        ) as $rate) {
            $allowed = self::rate_limit($rate[0], $rate[1], $rate[2], $rate[3]);
            if (is_wp_error($allowed)) { return $allowed; }
        }

        $lock = self::acquire_named_fan_lock(
            'collab_submit',
            $fan_user_id . '|' . (string) $input['submissionID']
        );
        if (is_wp_error($lock)) {
            return new WP_Error(
                'collaboration_submission_busy',
                '邀约正在提交，请稍后重试。',
                array('status' => 409)
            );
        }

        try {
            $existing = self::find_collaboration_submission(
                $fan_user_id,
                (string) $input['submissionID']
            );
            if (is_wp_error($existing)) { return $existing; }
            if (is_array($existing)) {
                return self::collaboration_submission_response($existing, $input['payloadHash'], true);
            }

            global $wpdb;
            $tables = self::collaboration_tables();
            if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'query')
                || !method_exists($wpdb, 'insert') || $wpdb->query('START TRANSACTION') === false) {
                return self::collaboration_storage_error();
            }
            $committed = false;
            try {
                // The permission callback ran before this method and account
                // state may have changed since then. Re-read and lock the
                // session, user and profile rows inside the write transaction;
                // never persist using the callback's stale snapshot.
                if (!self::collaboration_fan_context_is_current_from_database(
                    $context,
                    true
                )) {
                    if ($wpdb->query('ROLLBACK') === false) {
                        return self::collaboration_storage_error();
                    }
                    return new WP_Error(
                        'collaboration_fan_required',
                        '账号资料、权限或登录状态已变更，请重新登录后提交。',
                        array('status' => 403)
                    );
                }
                $public_id = strtolower((string) wp_generate_uuid4());
                if (!self::is_uuid_v4($public_id)) {
                    throw new RuntimeException('public_id_unavailable');
                }
                $now = gmdate('Y-m-d H:i:s');
                $inserted = $wpdb->insert($tables['requests'], array(
                    'public_id' => $public_id,
                    'submission_id' => (string) $input['submissionID'],
                    'fan_user_id' => $fan_user_id,
                    'install_hash' => hash('sha256', strtolower($install_id)),
                    'network_hash' => self::request_network_fingerprint(),
                    'contact_name' => (string) $input['contactName'],
                    'contact_method' => (string) $input['contactMethod'],
                    'organization' => (string) $input['organization'],
                    'project_type' => (string) $input['projectType'],
                    'city' => (string) $input['city'],
                    'preferred_date' => $input['preferredDate'] ?: null,
                    'budget' => (string) $input['budget'],
                    'details' => (string) $input['details'],
                    'payload_hash' => (string) $input['payloadHash'],
                    'status' => 'received',
                    'status_updated_by' => null,
                    'version' => 1,
                    'created_at' => $now,
                    'updated_at' => $now,
                ), array(
                    '%s', '%s', '%d', '%s', '%s', '%s', '%s', '%s', '%s', '%s',
                    '%s', '%s', '%s', '%s', '%s', '%d', '%d', '%s', '%s',
                ));
                if ($inserted !== 1) { throw new RuntimeException('request_insert_failed'); }
                $request_id = (int) $wpdb->insert_id;
                $outbox_inserted = $wpdb->insert($tables['outbox'], array(
                    'request_id' => $request_id,
                    'channel' => 'work_mail',
                    'dedupe_key' => hash('sha256', $public_id . '|work_mail'),
                    'status' => 'pending',
                    'attempts' => 0,
                    'next_attempt_at' => $now,
                    'lease_token' => null,
                    'lease_until' => null,
                    'last_error_code' => '',
                    'created_at' => $now,
                    'updated_at' => $now,
                ), array('%d', '%s', '%s', '%s', '%d', '%s', '%s', '%s', '%s', '%s', '%s'));
                if ($outbox_inserted !== 1) { throw new RuntimeException('outbox_insert_failed'); }
                $outbox_id = (int) $wpdb->insert_id;
                if (!self::record_collaboration_audit(
                    $request_id,
                    'fan',
                    $fan_user_id,
                    'request_received',
                    'accepted',
                    array('toStatus' => 'received')
                )) {
                    throw new RuntimeException('audit_insert_failed');
                }
                if ($wpdb->query('COMMIT') === false) {
                    throw new RuntimeException('commit_failed');
                }
                $committed = true;

                self::schedule_collaboration_outbox_job($outbox_id, time() + 5);
                return self::collaboration_submission_response(array(
                    'id' => $request_id,
                    'public_id' => $public_id,
                    'payload_hash' => (string) $input['payloadHash'],
                    'status' => 'received',
                    'created_at' => $now,
                ), $input['payloadHash'], false);
            } catch (Throwable $error) {
                if (!$committed) { $wpdb->query('ROLLBACK'); }
                do_action('yishu_collaboration_security_audit', 'submission_persistence_failed');
                return self::collaboration_storage_error();
            }
        } finally {
            self::release_named_fan_lock($lock);
        }
        } finally {
            self::release_fan_lock($fan_user_id, $fan_lock_owner);
        }
    }

    public static function list_collaboration_requests(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()) {
            return self::collaboration_feature_disabled_error();
        }
        if (!self::collaboration_storage_ready()) { return self::collaboration_storage_error(); }
        $status = sanitize_key((string) $request->get_param('status'));
        if ($status !== '' && !in_array($status, self::collaboration_request_statuses(), true)) {
            return new WP_Error(
                'collaboration_status_invalid',
                '合作邀约状态无效。',
                array('status' => 400)
            );
        }
        $page = min(100000, max(1, (int) $request->get_param('page')));
        $per_page = (int) $request->get_param('perPage');
        $per_page = $per_page > 0 ? min(100, $per_page) : 50;
        $offset = ($page - 1) * $per_page;

        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return self::collaboration_storage_error();
        }
        $select = "SELECT r.*, o.status AS mail_status, o.attempts AS mail_attempts,
                o.last_error_code AS mail_error_code
            FROM {$tables['requests']} r
            LEFT JOIN {$tables['outbox']} o
              ON o.request_id = r.id AND o.channel = 'work_mail'";
        if ($status !== '') {
            $rows = $wpdb->get_results($wpdb->prepare(
                $select . ' WHERE r.status = %s ORDER BY r.created_at DESC, r.id DESC LIMIT %d OFFSET %d',
                $status,
                $per_page,
                $offset
            ), ARRAY_A);
            // wpdb resets last_error on the next query. A failed list read
            // must not be turned into a successful, misleading empty inbox.
            if (!is_array($rows) || !empty($wpdb->last_error)) {
                return self::collaboration_storage_error();
            }
            $total = $wpdb->get_var($wpdb->prepare(
                "SELECT COUNT(*) FROM {$tables['requests']} WHERE status = %s",
                $status
            ));
        } else {
            $rows = $wpdb->get_results($wpdb->prepare(
                $select . ' ORDER BY r.created_at DESC, r.id DESC LIMIT %d OFFSET %d',
                $per_page,
                $offset
            ), ARRAY_A);
            if (!is_array($rows) || !empty($wpdb->last_error)) {
                return self::collaboration_storage_error();
            }
            $total = $wpdb->get_var("SELECT COUNT(*) FROM {$tables['requests']}");
        }
        if (!empty($wpdb->last_error)
            || (!is_string($total) && !is_int($total))
            || preg_match('/^[0-9]+$/D', (string) $total) !== 1
            || (string) (int) $total !== (string) $total) {
            return self::collaboration_storage_error();
        }
        $items = array();
        foreach ($rows as $row) {
            if (is_array($row)) { $items[] = self::collaboration_admin_record($row); }
        }
        $response = rest_ensure_response(array(
            'requests' => $items,
            'page' => $page,
            'perPage' => $per_page,
            'total' => (int) $total,
            'statuses' => self::collaboration_request_statuses(),
        ));
        self::set_private_no_store_headers($response);
        return $response;
    }

    public static function update_collaboration_request(WP_REST_Request $request) {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()) {
            return self::collaboration_feature_disabled_error();
        }
        if (!self::collaboration_storage_ready()) { return self::collaboration_storage_error(); }
        $public_id = strtolower(trim((string) $request->get_param('request_id')));
        if (!self::is_uuid_v4($public_id)) {
            return new WP_Error('collaboration_not_found', '合作邀约不存在。', array('status' => 404));
        }
        $status = sanitize_key((string) $request->get_param('status'));
        if (!in_array($status, self::collaboration_request_statuses(), true)) {
            return new WP_Error('collaboration_status_invalid', '合作邀约状态无效。', array('status' => 400));
        }
        $raw_version = $request->get_param('version');
        if (!is_scalar($raw_version) || !preg_match('/^[1-9][0-9]{0,18}$/', (string) $raw_version)) {
            return new WP_Error(
                'collaboration_version_required',
                '请刷新合作邀约后再更新。',
                array('status' => 400)
            );
        }
        $expected_version = (int) $raw_version;

        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'query')
            || !method_exists($wpdb, 'get_row') || !method_exists($wpdb, 'update')
            || $wpdb->query('START TRANSACTION') === false) {
            return self::collaboration_storage_error();
        }
        $committed = false;
        try {
            $row = $wpdb->get_row($wpdb->prepare(
                "SELECT * FROM {$tables['requests']} WHERE public_id = %s LIMIT 1 FOR UPDATE",
                $public_id
            ), ARRAY_A);
            if (!is_array($row)) {
                $wpdb->query('ROLLBACK');
                return new WP_Error('collaboration_not_found', '合作邀约不存在。', array('status' => 404));
            }
            if ((int) ($row['version'] ?? 0) !== $expected_version) {
                $wpdb->query('ROLLBACK');
                return new WP_Error(
                    'collaboration_version_conflict',
                    '合作邀约已被其他管理员更新，请刷新后重试。',
                    array('status' => 409)
                );
            }
            $previous_status = (string) $row['status'];
            if ($previous_status === $status) {
                if ($wpdb->query('COMMIT') === false) {
                    throw new RuntimeException('commit_failed');
                }
                $committed = true;
                $row = self::attach_collaboration_delivery($row);
                $response = rest_ensure_response(array(
                    'request' => self::collaboration_admin_record($row),
                ));
                self::set_private_no_store_headers($response);
                return $response;
            }
            $now = gmdate('Y-m-d H:i:s');
            $updated = $wpdb->update($tables['requests'], array(
                'status' => $status,
                'status_updated_by' => (int) get_current_user_id(),
                'version' => $expected_version + 1,
                'updated_at' => $now,
            ), array(
                'id' => (int) $row['id'],
                'version' => $expected_version,
            ), array('%s', '%d', '%d', '%s'), array('%d', '%d'));
            if ($updated !== 1 || !self::record_collaboration_audit(
                (int) $row['id'],
                'administrator',
                (int) get_current_user_id(),
                'request_status_updated',
                'accepted',
                array(
                    'fromStatus' => $previous_status,
                    'toStatus' => $status,
                    'version' => $expected_version + 1,
                )
            )) {
                throw new RuntimeException('status_update_failed');
            }
            if ($wpdb->query('COMMIT') === false) { throw new RuntimeException('commit_failed'); }
            $committed = true;
            $row['status'] = $status;
            $row['status_updated_by'] = (int) get_current_user_id();
            $row['version'] = $expected_version + 1;
            $row['updated_at'] = $now;
            $row = self::attach_collaboration_delivery($row);
            $response = rest_ensure_response(array(
                'request' => self::collaboration_admin_record($row),
            ));
            self::set_private_no_store_headers($response);
            return $response;
        } catch (Throwable $error) {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
            do_action('yishu_collaboration_security_audit', 'status_update_failed');
            return self::collaboration_storage_error();
        }
    }

    public static function ensure_collaboration_outbox_schedule() {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()
            || !self::account_authority_enabled()
            || !self::collaboration_storage_ready()) {
            return false;
        }
        if (wp_next_scheduled(self::COLLABORATION_SWEEP_HOOK) !== false) { return true; }
        $scheduled = wp_schedule_single_event(
            time() + 300,
            self::COLLABORATION_SWEEP_HOOK,
            array(),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            do_action('yishu_collaboration_security_audit', 'outbox_sweep_schedule_failed');
            return false;
        }
        return true;
    }

    public static function sweep_collaboration_outbox() {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()
            || !self::account_authority_enabled()
            || !self::collaboration_storage_ready()) {
            return false;
        }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_col')
            || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $now = gmdate('Y-m-d H:i:s');
        self::mark_exhausted_collaboration_outbox_jobs($now);
        $ids = $wpdb->get_col($wpdb->prepare(
            "SELECT id FROM {$tables['outbox']}
             WHERE attempts < %d AND next_attempt_at <= %s
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))
             ORDER BY next_attempt_at ASC, id ASC LIMIT 20",
            self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
            $now,
            $now
        ));
        if (is_array($ids)) {
            foreach ($ids as $id) {
                if ((int) $id > 0) { self::process_collaboration_outbox((int) $id); }
            }
        }
        self::ensure_collaboration_outbox_schedule();
        return is_array($ids);
    }

    public static function process_collaboration_outbox($job_id) {
        $job_id = (int) $job_id;
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()
            || $job_id <= 0
            || !self::account_authority_enabled()
            || !self::collaboration_storage_ready()) {
            return false;
        }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'query')
            || !method_exists($wpdb, 'get_row') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        try {
            $lease_token = bin2hex(random_bytes(16));
        } catch (Throwable $error) {
            return false;
        }
        $now = gmdate('Y-m-d H:i:s');
        $lease_until = gmdate('Y-m-d H:i:s', time() + self::COLLABORATION_OUTBOX_LEASE_SECONDS);
        $claimed = $wpdb->query($wpdb->prepare(
            "UPDATE {$tables['outbox']}
             SET status = 'processing', attempts = attempts + 1,
                 lease_token = %s, lease_until = %s, updated_at = %s
             WHERE id = %d AND attempts < %d AND next_attempt_at <= %s
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))",
            $lease_token,
            $lease_until,
            $now,
            $job_id,
            self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
            $now,
            $now
        ));
        if ($claimed !== 1) { return false; }
        $job = $wpdb->get_row($wpdb->prepare(
            "SELECT o.*, r.public_id, r.contact_name, r.contact_method,
                    r.organization, r.project_type, r.city, r.preferred_date,
                    r.budget, r.details
             FROM {$tables['outbox']} o
             INNER JOIN {$tables['requests']} r ON r.id = o.request_id
             WHERE o.id = %d AND o.lease_token = %s LIMIT 1",
            $job_id,
            $lease_token
        ), ARRAY_A);
        if (!is_array($job)) {
            self::fail_collaboration_outbox_job($job_id, $lease_token, 1, 'request_missing');
            return false;
        }

        $sent = false;
        $error_code = 'mail_rejected';
        if ((string) ($job['channel'] ?? '') !== 'work_mail') {
            $error_code = 'channel_invalid';
        } else {
            $recipient = self::collaboration_work_email();
            if (!$recipient) {
                $error_code = 'recipient_unavailable';
            } else {
                try {
                    $sent = wp_mail(
                        $recipient,
                        '易姝合作邀约 #' . (string) $job['public_id'],
                        self::collaboration_mail_body($job),
                        array('Content-Type: text/plain; charset=UTF-8')
                    ) === true;
                } catch (Throwable $error) {
                    $sent = false;
                    $error_code = 'mail_exception';
                }
            }
        }
        if (!$sent) {
            self::fail_collaboration_outbox_job(
                $job_id,
                $lease_token,
                (int) ($job['attempts'] ?? 1),
                $error_code
            );
            return false;
        }

        $updated = $wpdb->update($tables['outbox'], array(
            'status' => 'sent',
            'lease_token' => null,
            'lease_until' => null,
            'last_error_code' => '',
            'updated_at' => gmdate('Y-m-d H:i:s'),
        ), array(
            'id' => $job_id,
            'lease_token' => $lease_token,
        ), array('%s', '%s', '%s', '%s', '%s'), array('%d', '%s'));
        if ($updated !== 1) { return false; }
        self::record_collaboration_audit(
            (int) $job['request_id'],
            'system',
            0,
            'work_mail_accepted',
            'accepted',
            array('channel' => 'work_mail', 'attempt' => (int) $job['attempts'])
        );
        return true;
    }

    public static function purge_collaboration_data_for_fan_user($fan_user_id) {
        $fan_user_id = (int) $fan_user_id;
        if ($fan_user_id <= 0) { return false; }

        // Cleanup must remain available after the feature is disabled. A future
        // rollback, lost option row or corrupt schema marker must not strand
        // data that an earlier enabled release wrote. The physical tables are
        // the authority for deletion, never the optional schema marker.
        global $wpdb;
        $tables = self::collaboration_table_names();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_var')
            || !method_exists($wpdb, 'get_col') || !method_exists($wpdb, 'prepare')
            || !method_exists($wpdb, 'esc_like') || !method_exists($wpdb, 'query')) {
            return false;
        }

        $present = 0;
        foreach ($tables as $table) {
            $found = $wpdb->get_var($wpdb->prepare(
                'SHOW TABLES LIKE %s',
                $wpdb->esc_like($table)
            ));
            if (!empty($wpdb->last_error)) {
                do_action('yishu_collaboration_security_audit', 'account_deletion_schema_probe_failed');
                return false;
            }
            if (is_string($found) && hash_equals($table, $found)) { $present++; }
        }
        if ($present === 0) { return true; }
        if ($present !== count($tables)) {
            do_action('yishu_collaboration_security_audit', 'account_deletion_schema_incomplete');
            return false;
        }
        // A physical table existing is not proof that DELETE can roll back.
        // Validate without the feature/ready option, which may be absent after
        // rollback. Never partially erase child rows in nontransactional tables.
        if (!self::collaboration_schema_matches($tables)) {
            do_action('yishu_collaboration_security_audit', 'account_deletion_schema_incompatible');
            return false;
        }

        if ($wpdb->query('START TRANSACTION') === false) { return false; }
        $committed = false;
        try {
            $request_ids = $wpdb->get_col($wpdb->prepare(
                "SELECT id FROM {$tables['requests']}
                 WHERE fan_user_id = %d ORDER BY id ASC FOR UPDATE",
                $fan_user_id
            ));
            if (!is_array($request_ids) || !empty($wpdb->last_error)) {
                throw new RuntimeException('collaboration_delete_lookup_failed');
            }
            foreach ($request_ids as $request_id) {
                if (!is_scalar($request_id) || !ctype_digit((string) $request_id)
                    || (int) $request_id <= 0) {
                    throw new RuntimeException('collaboration_delete_lookup_invalid');
                }
            }
            $request_ids = array_map('intval', array_values($request_ids));
            if (count(array_unique($request_ids)) !== count($request_ids)) {
                throw new RuntimeException('collaboration_delete_lookup_invalid');
            }
            if ($request_ids) {
                // Child rows are removed first so no queued delivery or audit
                // record can remain linked to the deleted fan or its PII.
                $audit_deleted = $wpdb->query($wpdb->prepare(
                    "DELETE a FROM {$tables['audit']} a
                     INNER JOIN {$tables['requests']} r ON r.id = a.request_id
                     WHERE r.fan_user_id = %d",
                    $fan_user_id
                ));
                $outbox_deleted = $wpdb->query($wpdb->prepare(
                    "DELETE o FROM {$tables['outbox']} o
                     INNER JOIN {$tables['requests']} r ON r.id = o.request_id
                     WHERE r.fan_user_id = %d",
                    $fan_user_id
                ));
                $requests_deleted = $wpdb->query($wpdb->prepare(
                    "DELETE FROM {$tables['requests']} WHERE fan_user_id = %d",
                    $fan_user_id
                ));
                if ($audit_deleted === false || $outbox_deleted === false
                    || $requests_deleted !== count($request_ids)) {
                    throw new RuntimeException('collaboration_delete_failed');
                }
            }
            if ($wpdb->query('COMMIT') === false) {
                throw new RuntimeException('collaboration_delete_commit_failed');
            }
            $committed = true;
            return true;
        } catch (Throwable $error) {
            if (!$committed) { $wpdb->query('ROLLBACK'); }
            do_action('yishu_collaboration_security_audit', 'account_deletion_cleanup_failed');
            return false;
        }
    }

    private static function collaboration_fan_context_is_current_from_database(
        $context,
        $for_update = false
    ) {
        if (!is_array($context)
            || ($context['scope'] ?? '') !== 'normal'
            || !self::fan_session_context_is_current_from_database(
                $context,
                'normal',
                (bool) $for_update
            )) {
            return false;
        }

        $fan_user_id = (int) ($context['userID'] ?? 0);
        global $wpdb;
        if ($fan_user_id <= 0 || !isset($wpdb->users)
            || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $locking_clause = $for_update ? ' FOR UPDATE' : '';
        $display_name = $wpdb->get_var($wpdb->prepare(
            "SELECT display_name FROM {$wpdb->users} WHERE ID = %d LIMIT 1{$locking_clause}",
            $fan_user_id
        ));
        if (!is_string($display_name) || !empty($wpdb->last_error)
            || is_wp_error(self::validate_fan_display_name($display_name))) {
            return false;
        }

        $uuid = (string) self::fan_meta_from_database(
            $fan_user_id,
            self::FAN_META_UUID,
            '',
            (bool) $for_update
        );
        if (!empty($wpdb->last_error)
            || preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/', $uuid) !== 1) {
            return false;
        }
        $identity_code = (string) self::fan_meta_from_database(
            $fan_user_id,
            self::FAN_META_CODE,
            '',
            (bool) $for_update
        );
        if (!empty($wpdb->last_error) || $identity_code === ''
            || self::normalize_identity_code($identity_code) !== $identity_code) {
            return false;
        }
        $status = (string) self::fan_meta_from_database(
            $fan_user_id,
            self::FAN_META_STATUS,
            '',
            (bool) $for_update
        );
        if (!empty($wpdb->last_error) || $status !== 'active') { return false; }

        foreach (array(
            self::FAN_META_INVITATION,
            self::FAN_META_PASSWORD_RECOVERY,
            self::FAN_META_APPLE_SETUP,
        ) as $incomplete_marker) {
            $marker = self::fan_meta_from_database(
                $fan_user_id,
                $incomplete_marker,
                null,
                (bool) $for_update
            );
            if (!empty($wpdb->last_error) || !empty($marker)) { return false; }
        }

        $stored_douyin_id = (string) self::fan_meta_from_database(
            $fan_user_id,
            self::FAN_META_DOUYIN_ID,
            '',
            (bool) $for_update
        );
        $douyin_id = self::normalize_required_douyin_id($stored_douyin_id);
        if (!empty($wpdb->last_error) || is_wp_error($douyin_id)
            || !hash_equals($stored_douyin_id, (string) $douyin_id)) {
            return false;
        }

        $consent = self::fan_meta_from_database(
            $fan_user_id,
            self::FAN_META_CONSENT,
            null,
            (bool) $for_update
        );
        if (!empty($wpdb->last_error) || !self::fan_stored_consent_is_accepted($consent)) {
            return false;
        }

        $fresh_permissions = self::fan_meta_from_database(
            $fan_user_id,
            self::FAN_META_PERMISSIONS,
            null,
            (bool) $for_update
        );
        if (!empty($wpdb->last_error) || !is_array($fresh_permissions)) { return false; }
        $fresh_permissions = self::sanitize_fan_permissions($fresh_permissions);
        $callback_permissions = self::sanitize_fan_permissions(
            isset($context['permissions']) && is_array($context['permissions'])
                ? $context['permissions']
                : array()
        );
        if (is_wp_error($fresh_permissions) || is_wp_error($callback_permissions)) {
            return false;
        }
        sort($fresh_permissions, SORT_STRING);
        sort($callback_permissions, SORT_STRING);
        return $fresh_permissions === $callback_permissions;
    }

    private static function collaboration_table_names() {
        global $wpdb;
        if (!isset($wpdb) || !isset($wpdb->prefix) || !is_string($wpdb->prefix)
            || preg_match('/^[A-Za-z0-9_]+$/D', $wpdb->prefix) !== 1) { return array(); }
        $tables = array(
            'requests' => $wpdb->prefix . 'yishu_collaboration_requests',
            'outbox' => $wpdb->prefix . 'yishu_collaboration_outbox',
            'audit' => $wpdb->prefix . 'yishu_collaboration_audit',
        );
        foreach ($tables as $table) {
            if (strlen($table) > 64) { return array(); }
        }
        return $tables;
    }

    private static function collaboration_tables() {
        if (!self::collaboration_phase1_enabled()) { return null; }
        return self::collaboration_table_names();
    }

    private static function collaboration_tables_exist() {
        if (!self::collaboration_phase1_enabled()) { return false; }
        return self::collaboration_schema_matches(self::collaboration_tables());
    }

    /** Read metadata only; never repair an incompatible live table implicitly. */
    private static function collaboration_schema_matches($tables) {
        global $wpdb;
        $expected = self::collaboration_schema_contract();
        if (!is_array($tables) || array_keys($tables) !== array_keys($expected)
            || !isset($wpdb) || !method_exists($wpdb, 'get_row')
            || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'prepare') || !method_exists($wpdb, 'esc_like')) {
            return false;
        }
        try {
            foreach ($tables as $name => $table) {
                // Identifiers cannot use value placeholders. Only admit the
                // WordPress prefix grammar and MySQL's 64-character limit.
                if (!is_string($table) || preg_match('/^[A-Za-z0-9_]{1,64}$/D', $table) !== 1) {
                    return false;
                }
                $status = $wpdb->get_row($wpdb->prepare(
                    'SHOW TABLE STATUS LIKE %s', $wpdb->esc_like($table)
                ), ARRAY_A);
                if (!empty($wpdb->last_error) || !is_array($status)
                    || ($status['Name'] ?? null) !== $table
                    || strcasecmp((string) ($status['Engine'] ?? ''), 'InnoDB') !== 0) {
                    return false;
                }
                $columns = $wpdb->get_results("SHOW FULL COLUMNS FROM `{$table}`", ARRAY_A);
                if (!empty($wpdb->last_error)
                    || !self::collaboration_columns_match($columns, $expected[$name]['columns'])) {
                    return false;
                }
                $indexes = $wpdb->get_results("SHOW INDEX FROM `{$table}`", ARRAY_A);
                if (!empty($wpdb->last_error)
                    || !self::collaboration_indexes_match($indexes, $expected[$name]['indexes'])) {
                    return false;
                }
            }
        } catch (Throwable $error) {
            // Neither SQL nor an exception message belongs in an audit event.
            return false;
        }
        return true;
    }

    private static function collaboration_columns_match($rows, $expected) {
        if (!is_array($rows) || count($rows) !== count($expected)) { return false; }
        $seen = array();
        foreach ($rows as $row) {
            if (!is_array($row)) { return false; }
            foreach (array('Field', 'Type', 'Null', 'Default', 'Extra') as $key) {
                if (!array_key_exists($key, $row)) { return false; }
            }
            $name = $row['Field'];
            if (!is_string($name) || !isset($expected[$name]) || isset($seen[$name])
                || !is_string($row['Type'])) { return false; }
            // MySQL 8 may omit integer display widths; MariaDB retains them.
            // Width is cosmetic, unlike unsigned, precision or string length.
            $type = preg_replace('/^(bigint|smallint)\([0-9]+\)/', '$1', strtolower($row['Type']));
            $default = $row['Default'];
            if (is_int($default)) { $default = (string) $default; }
            if (array($type, $row['Null'], $default, $row['Extra']) !== $expected[$name]) {
                return false;
            }
            $seen[$name] = true;
        }
        return count($seen) === count($expected);
    }

    private static function collaboration_indexes_match($rows, $expected) {
        if (!is_array($rows)) { return false; }
        $actual = array();
        foreach ($rows as $row) {
            if (!is_array($row)) { return false; }
            foreach (array('Key_name', 'Non_unique', 'Seq_in_index', 'Column_name', 'Sub_part', 'Index_type') as $key) {
                if (!array_key_exists($key, $row)) { return false; }
            }
            $name = $row['Key_name'];
            $sequence = (string) $row['Seq_in_index'];
            if (!is_string($name) || !isset($expected[$name])
                || preg_match('/^[1-9][0-9]*$/D', $sequence) !== 1
                || (string) $row['Non_unique'] !== $expected[$name][0]
                || !is_string($row['Column_name']) || $row['Sub_part'] !== null
                || strtoupper((string) $row['Index_type']) !== 'BTREE'
                || (isset($row['Visible']) && $row['Visible'] !== 'YES')
                || (isset($row['Ignored']) && $row['Ignored'] !== 'NO')
                || (isset($row['Collation']) && $row['Collation'] !== 'A')
                || isset($actual[$name][(int) $sequence])) {
                return false;
            }
            $actual[$name][(int) $sequence] = $row['Column_name'];
        }
        if (count($actual) !== count($expected)) { return false; }
        foreach ($expected as $name => $contract) {
            $columns = $actual[$name] ?? array();
            ksort($columns, SORT_NUMERIC);
            if (array_keys($columns) !== range(1, count($contract[1]))
                || array_values($columns) !== $contract[1]) { return false; }
        }
        return true;
    }

    /** [type, nullable, default, extra]; indexes: [non_unique, ordered columns]. */
    private static function collaboration_schema_contract() {
        $id = array('bigint unsigned', 'NO', null, 'auto_increment');
        $reference = array('bigint unsigned', 'NO', null, '');
        $timestamp = array('datetime', 'NO', null, '');
        return array(
            'requests' => array(
                'columns' => array(
                    'id' => $id,
                    'public_id' => array('char(36)', 'NO', null, ''),
                    'submission_id' => array('char(36)', 'NO', null, ''),
                    'fan_user_id' => $reference,
                    'install_hash' => array('char(64)', 'NO', null, ''),
                    'network_hash' => array('char(64)', 'NO', null, ''),
                    'contact_name' => array('varchar(120)', 'NO', null, ''),
                    'contact_method' => array('varchar(255)', 'NO', null, ''),
                    'organization' => array('varchar(160)', 'NO', '', ''),
                    'project_type' => array('varchar(40)', 'NO', null, ''),
                    'city' => array('varchar(120)', 'NO', '', ''),
                    'preferred_date' => array('date', 'YES', null, ''),
                    'budget' => array('varchar(120)', 'NO', '', ''),
                    'details' => array('text', 'NO', null, ''),
                    'payload_hash' => array('char(64)', 'NO', null, ''),
                    'status' => array('varchar(24)', 'NO', 'received', ''),
                    'status_updated_by' => array('bigint unsigned', 'YES', null, ''),
                    'version' => array('bigint unsigned', 'NO', '1', ''),
                    'created_at' => $timestamp,
                    'updated_at' => $timestamp,
                ),
                'indexes' => array(
                    'PRIMARY' => array('0', array('id')),
                    'public_id' => array('0', array('public_id')),
                    'fan_submission' => array('0', array('fan_user_id', 'submission_id')),
                    'status_created' => array('1', array('status', 'created_at')),
                    'fan_created' => array('1', array('fan_user_id', 'created_at')),
                ),
            ),
            'outbox' => array(
                'columns' => array(
                    'id' => $id,
                    'request_id' => $reference,
                    'channel' => array('varchar(32)', 'NO', null, ''),
                    'dedupe_key' => array('char(64)', 'NO', null, ''),
                    'status' => array('varchar(20)', 'NO', 'pending', ''),
                    'attempts' => array('smallint unsigned', 'NO', '0', ''),
                    'next_attempt_at' => $timestamp,
                    'lease_token' => array('char(32)', 'YES', null, ''),
                    'lease_until' => array('datetime', 'YES', null, ''),
                    'last_error_code' => array('varchar(80)', 'NO', '', ''),
                    'created_at' => $timestamp,
                    'updated_at' => $timestamp,
                ),
                'indexes' => array(
                    'PRIMARY' => array('0', array('id')),
                    'dedupe_key' => array('0', array('dedupe_key')),
                    'due_jobs' => array('1', array('status', 'next_attempt_at')),
                    'request_channel' => array('0', array('request_id', 'channel')),
                ),
            ),
            'audit' => array(
                'columns' => array(
                    'id' => $id,
                    'request_id' => $reference,
                    'actor_type' => array('varchar(20)', 'NO', null, ''),
                    'actor_id' => array('bigint unsigned', 'NO', '0', ''),
                    'event' => array('varchar(64)', 'NO', null, ''),
                    'result' => array('varchar(32)', 'NO', null, ''),
                    'metadata_json' => array('text', 'NO', null, ''),
                    'created_at' => $timestamp,
                ),
                'indexes' => array(
                    'PRIMARY' => array('0', array('id')),
                    'request_created' => array('1', array('request_id', 'created_at')),
                    'event_created' => array('1', array('event', 'created_at')),
                ),
            ),
        );
    }

    private static function collaboration_storage_ready() {
        return self::collaboration_phase1_enabled()
            && self::account_authority_enabled()
            && (int) get_option(self::COLLABORATION_SCHEMA_OPTION, 0)
                === self::COLLABORATION_SCHEMA_VERSION
            && self::collaboration_tables_exist();
    }

    private static function collaboration_feature_disabled_error() {
        return new WP_Error(
            'collaboration_feature_disabled',
            '合作邀约服务尚未开放。',
            array('status' => 404)
        );
    }

    private static function collaboration_storage_error() {
        return new WP_Error(
            'collaboration_storage_unavailable',
            '合作邀约服务暂时不可用，请稍后重试。',
            array('status' => 503)
        );
    }

    private static function sanitize_collaboration_submission(WP_REST_Request $request) {
        $raw_submission_id = $request->get_param('submissionID');
        $submission_id = is_string($raw_submission_id)
            ? strtolower(trim((string) $raw_submission_id))
            : '';
        if (!self::is_uuid_v4($submission_id)) {
            return new WP_Error(
                'collaboration_submission_id_invalid',
                '提交标识无效，请重新打开页面后再试。',
                array('status' => 400)
            );
        }
        $fields = array();
        foreach (array(
            'contactName' => array(true, 80),
            'contactMethod' => array(true, 160),
            'organization' => array(false, 120),
            'city' => array(false, 80),
            'budget' => array(false, 80),
        ) as $name => $rules) {
            $value = self::normalize_collaboration_single_line(
                $request->get_param($name),
                $rules[0],
                $rules[1]
            );
            if (is_wp_error($value)) { return $value; }
            $fields[$name] = $value;
        }
        $raw_project_type = $request->get_param('projectType');
        $project_type = is_string($raw_project_type)
            ? sanitize_key((string) $raw_project_type)
            : '';
        if (!in_array($project_type, array(
            'drama', 'commercial', 'brand', 'modeling', 'event', 'other',
        ), true)) {
            return new WP_Error(
                'collaboration_project_type_invalid',
                '请选择有效的合作类型。',
                array('status' => 400)
            );
        }
        $preferred_date = self::normalize_collaboration_date(
            $request->get_param('preferredDate')
        );
        if (is_wp_error($preferred_date)) { return $preferred_date; }
        $details = self::normalize_collaboration_details($request->get_param('details'));
        if (is_wp_error($details)) { return $details; }
        $normalized = array(
            'submissionID' => $submission_id,
            'contactName' => $fields['contactName'],
            'contactMethod' => $fields['contactMethod'],
            'organization' => $fields['organization'],
            'projectType' => $project_type,
            'city' => $fields['city'],
            'preferredDate' => $preferred_date,
            'budget' => $fields['budget'],
            'details' => $details,
        );
        $encoded = wp_json_encode($normalized, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if (!is_string($encoded)) {
            return new WP_Error(
                'collaboration_payload_invalid',
                '合作邀约内容无效。',
                array('status' => 400)
            );
        }
        $normalized['payloadHash'] = hash('sha256', $encoded);
        return $normalized;
    }

    private static function normalize_collaboration_single_line($value, $required, $maximum) {
        if ($value === null && !$required) { return ''; }
        if (!is_string($value)) {
            return new WP_Error('collaboration_field_invalid', '合作邀约字段无效。', array('status' => 400));
        }
        $raw = (string) $value;
        if (strlen($raw) > (int) $maximum * 4 + 16 || preg_match('//u', $raw) !== 1
            || preg_match('/[\x00-\x1F\x7F]/', $raw)) {
            return new WP_Error('collaboration_field_invalid', '合作邀约字段无效。', array('status' => 400));
        }
        $raw = trim($raw);
        $normalized = sanitize_text_field($raw);
        $length = self::collaboration_text_length($normalized);
        if (($required && $length < 1) || $length > (int) $maximum) {
            return new WP_Error('collaboration_field_invalid', '合作邀约字段长度无效。', array('status' => 400));
        }
        return $normalized;
    }

    private static function normalize_collaboration_details($value) {
        if ($value === null) { return ''; }
        if (!is_string($value)) {
            return new WP_Error('collaboration_details_invalid', '项目说明无效。', array('status' => 400));
        }
        $raw = (string) $value;
        if (strlen($raw) > 16016 || preg_match('//u', $raw) !== 1) {
            return new WP_Error('collaboration_details_invalid', '项目说明过长或格式无效。', array('status' => 400));
        }
        $raw = str_replace(array("\r\n", "\r"), "\n", $raw);
        if (preg_match('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', $raw)) {
            return new WP_Error('collaboration_details_invalid', '项目说明包含无效字符。', array('status' => 400));
        }
        $normalized = trim(strip_tags($raw));
        if (self::collaboration_text_length($normalized) > 4000) {
            return new WP_Error('collaboration_details_invalid', '项目说明不能超过 4000 个字符。', array('status' => 400));
        }
        return $normalized;
    }

    private static function collaboration_text_length($value) {
        if (function_exists('mb_strlen')) { return mb_strlen((string) $value, 'UTF-8'); }
        $count = preg_match_all('/./us', (string) $value, $matches);
        return is_int($count) && $count >= 0 ? $count : strlen((string) $value);
    }

    private static function normalize_collaboration_date($value) {
        if ($value === null || $value === '') { return ''; }
        if (!is_string($value)) {
            return new WP_Error('collaboration_date_invalid', '预计日期无效。', array('status' => 400));
        }
        $date = trim((string) $value);
        if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/D', $date, $matches)
            || !checkdate((int) $matches[2], (int) $matches[3], (int) $matches[1])) {
            return new WP_Error('collaboration_date_invalid', '预计日期必须使用 YYYY-MM-DD 格式。', array('status' => 400));
        }
        $timestamp = gmmktime(0, 0, 0, (int) $matches[2], (int) $matches[3], (int) $matches[1]);
        $today = strtotime(gmdate('Y-m-d') . ' 00:00:00 UTC');
        $latest = strtotime('+5 years', $today);
        if ($timestamp < $today - DAY_IN_SECONDS || $timestamp > $latest) {
            return new WP_Error('collaboration_date_invalid', '预计日期不在可接受范围内。', array('status' => 400));
        }
        return $date;
    }

    private static function is_uuid_v4($value) {
        return is_string($value)
            && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/D', $value) === 1;
    }

    private static function find_collaboration_submission($fan_user_id, $submission_id) {
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_row')
            || !method_exists($wpdb, 'prepare')) {
            return self::collaboration_storage_error();
        }
        $row = $wpdb->get_row($wpdb->prepare(
            "SELECT id, public_id, payload_hash, status, created_at
             FROM {$tables['requests']}
             WHERE fan_user_id = %d AND submission_id = %s LIMIT 1",
            (int) $fan_user_id,
            (string) $submission_id
        ), ARRAY_A);
        if (!empty($wpdb->last_error)) { return self::collaboration_storage_error(); }
        return is_array($row) ? $row : null;
    }

    private static function collaboration_submission_response($row, $payload_hash, $duplicate) {
        if (!is_array($row) || empty($row['public_id']) || empty($row['payload_hash'])
            || !hash_equals((string) $row['payload_hash'], (string) $payload_hash)) {
            return new WP_Error(
                'collaboration_idempotency_conflict',
                '该提交标识已用于其他内容，请重新打开页面后再试。',
                array('status' => 409)
            );
        }
        $status = (string) ($row['status'] ?? '');
        if (!in_array($status, self::collaboration_request_statuses(), true)) {
            return self::collaboration_storage_error();
        }
        $response = new WP_REST_Response(array(
            'requestID' => (string) $row['public_id'],
            'status' => $status,
            'receivedAt' => self::collaboration_iso_time((string) ($row['created_at'] ?? '')),
            'duplicate' => (bool) $duplicate,
        ), $duplicate ? 200 : 201);
        self::set_private_no_store_headers($response);
        return $response;
    }

    private static function collaboration_request_statuses() {
        return array('received', 'reviewing', 'contacted', 'closed', 'spam');
    }

    private static function collaboration_admin_record($row) {
        $fan_user_id = (int) ($row['fan_user_id'] ?? 0);
        $fan_uuid = $fan_user_id > 0
            ? strtolower((string) get_user_meta($fan_user_id, self::FAN_META_UUID, true))
            : '';
        return array(
            'requestID' => (string) ($row['public_id'] ?? ''),
            'fanUserID' => self::is_uuid_v4($fan_uuid) ? $fan_uuid : '',
            'contactName' => (string) ($row['contact_name'] ?? ''),
            'contactMethod' => (string) ($row['contact_method'] ?? ''),
            'organization' => (string) ($row['organization'] ?? ''),
            'projectType' => (string) ($row['project_type'] ?? ''),
            'city' => (string) ($row['city'] ?? ''),
            'preferredDate' => (string) ($row['preferred_date'] ?? ''),
            'budget' => (string) ($row['budget'] ?? ''),
            'details' => (string) ($row['details'] ?? ''),
            'status' => (string) ($row['status'] ?? 'received'),
            'version' => max(1, (int) ($row['version'] ?? 1)),
            'receivedAt' => self::collaboration_iso_time((string) ($row['created_at'] ?? '')),
            'updatedAt' => self::collaboration_iso_time((string) ($row['updated_at'] ?? '')),
            'delivery' => array(
                'status' => (string) ($row['mail_status'] ?? 'pending'),
                'attempts' => max(0, (int) ($row['mail_attempts'] ?? 0)),
                'errorCode' => sanitize_key((string) ($row['mail_error_code'] ?? '')),
            ),
        );
    }

    private static function attach_collaboration_delivery($row) {
        if (!is_array($row) || (int) ($row['id'] ?? 0) <= 0) { return $row; }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_row')
            || !method_exists($wpdb, 'prepare')) {
            return $row;
        }
        $delivery = $wpdb->get_row($wpdb->prepare(
            "SELECT status, attempts, last_error_code FROM {$tables['outbox']}
             WHERE request_id = %d AND channel = 'work_mail' LIMIT 1",
            (int) $row['id']
        ), ARRAY_A);
        if (is_array($delivery)) {
            $row['mail_status'] = (string) ($delivery['status'] ?? 'pending');
            $row['mail_attempts'] = (int) ($delivery['attempts'] ?? 0);
            $row['mail_error_code'] = (string) ($delivery['last_error_code'] ?? '');
        }
        return $row;
    }

    private static function collaboration_iso_time($database_time) {
        $database_time = trim((string) $database_time);
        if (!preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/D', $database_time)) {
            return '';
        }
        return str_replace(' ', 'T', $database_time) . 'Z';
    }

    private static function set_private_no_store_headers($response) {
        if ($response instanceof WP_REST_Response) {
            $response->header('Cache-Control', 'private, no-store, max-age=0');
            $response->header('Pragma', 'no-cache');
            $response->header('Vary', 'Authorization, X-Yishu-Install-ID');
        }
    }

    private static function sanitize_collaboration_audit_metadata($metadata) {
        if (!is_array($metadata)) { return array(); }
        $allowed = array(
            'fromStatus', 'toStatus', 'channel', 'attempt', 'errorCode', 'version',
        );
        $result = array();
        foreach ($allowed as $key) {
            if (!array_key_exists($key, $metadata) || !is_scalar($metadata[$key])) { continue; }
            if (in_array($key, array('attempt', 'version'), true)) {
                $value = max(0, (int) $metadata[$key]);
            } else {
                $value = sanitize_key((string) $metadata[$key]);
                if ($value === '' || strlen($value) > 80) { continue; }
            }
            $result[$key] = $value;
        }
        return $result;
    }

    private static function record_collaboration_audit(
        $request_id,
        $actor_type,
        $actor_id,
        $event,
        $result,
        $metadata = array()
    ) {
        $actor_type = sanitize_key((string) $actor_type);
        $event = sanitize_key((string) $event);
        $result = sanitize_key((string) $result);
        if ((int) $request_id <= 0
            || !in_array($actor_type, array('fan', 'administrator', 'system'), true)
            || !in_array($event, array(
                'request_received', 'request_status_updated', 'work_mail_accepted',
                'work_mail_schedule_failed', 'work_mail_retry_scheduled', 'work_mail_dead',
            ), true)
            || !in_array($result, array('accepted', 'retry', 'dead'), true)) {
            return false;
        }
        if (!self::collaboration_phase1_enabled()) { return false; }
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'insert')) { return false; }
        $encoded = wp_json_encode(self::sanitize_collaboration_audit_metadata($metadata));
        if (!is_string($encoded) || strlen($encoded) > 1024) { return false; }
        return $wpdb->insert($tables['audit'], array(
            'request_id' => (int) $request_id,
            'actor_type' => $actor_type,
            'actor_id' => max(0, (int) $actor_id),
            'event' => $event,
            'result' => $result,
            'metadata_json' => $encoded,
            'created_at' => gmdate('Y-m-d H:i:s'),
        ), array('%d', '%s', '%d', '%s', '%s', '%s', '%s')) === 1;
    }

    private static function schedule_collaboration_outbox_job($job_id, $timestamp) {
        if (!self::collaboration_phase1_enabled()
            || !self::collaboration_mail_transport_ready()
            || (int) $job_id <= 0
            || !self::account_authority_enabled()) { return false; }
        $scheduled = wp_schedule_single_event(
            max(time() + 1, (int) $timestamp),
            self::COLLABORATION_OUTBOX_HOOK,
            array((int) $job_id),
            true
        );
        if (is_wp_error($scheduled) || !$scheduled) {
            // The durable pending row remains the source of truth. The
            // authority-only sweeper will reclaim it without losing the request.
            self::record_collaboration_outbox_audit(
                (int) $job_id,
                'work_mail_schedule_failed',
                'retry',
                array(
                    'channel' => 'work_mail',
                    'attempt' => 0,
                    'errorCode' => 'schedule_unavailable',
                )
            );
            do_action('yishu_collaboration_security_audit', 'outbox_job_schedule_failed');
            return false;
        }
        return true;
    }

    private static function record_collaboration_outbox_audit(
        $job_id,
        $event,
        $result,
        $metadata
    ) {
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || (int) $job_id <= 0 || !isset($wpdb)
            || !method_exists($wpdb, 'get_var') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $request_id = (int) $wpdb->get_var($wpdb->prepare(
            "SELECT request_id FROM {$tables['outbox']} WHERE id = %d LIMIT 1",
            (int) $job_id
        ));
        return $request_id > 0 && self::record_collaboration_audit(
            $request_id,
            'system',
            0,
            (string) $event,
            (string) $result,
            $metadata
        );
    }

    private static function collaboration_retry_delay($attempts) {
        $delays = array(60, 300, 1800, 7200);
        $index = max(0, min(count($delays) - 1, (int) $attempts - 1));
        return $delays[$index];
    }

    private static function mark_exhausted_collaboration_outbox_jobs($now) {
        global $wpdb;
        $tables = self::collaboration_tables();
        if (!$tables || !isset($wpdb) || !method_exists($wpdb, 'get_results')
            || !method_exists($wpdb, 'query') || !method_exists($wpdb, 'prepare')) {
            return false;
        }
        $rows = $wpdb->get_results($wpdb->prepare(
            "SELECT id, request_id, attempts FROM {$tables['outbox']}
             WHERE attempts >= %d
               AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))
             ORDER BY id ASC LIMIT 20",
            self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
            (string) $now
        ), ARRAY_A);
        if (!is_array($rows)) { return false; }
        foreach ($rows as $row) {
            if (!is_array($row) || (int) ($row['id'] ?? 0) <= 0) { continue; }
            $updated = $wpdb->query($wpdb->prepare(
                "UPDATE {$tables['outbox']}
                 SET status = 'dead', lease_token = NULL, lease_until = NULL,
                     last_error_code = 'worker_interrupted', updated_at = %s
                 WHERE id = %d AND attempts >= %d
                   AND (status = 'pending' OR (status = 'processing' AND lease_until <= %s))",
                (string) $now,
                (int) $row['id'],
                self::COLLABORATION_OUTBOX_MAX_ATTEMPTS,
                (string) $now
            ));
            if ($updated === 1) {
                self::record_collaboration_audit(
                    (int) ($row['request_id'] ?? 0),
                    'system',
                    0,
                    'work_mail_dead',
                    'dead',
                    array(
                        'channel' => 'work_mail',
                        'attempt' => (int) ($row['attempts'] ?? 0),
                        'errorCode' => 'worker_interrupted',
                    )
                );
            }
        }
        return true;
    }

    private static function collaboration_outbox_failure_state($attempts) {
        $attempts = max(1, (int) $attempts);
        if ($attempts >= self::COLLABORATION_OUTBOX_MAX_ATTEMPTS) {
            return array('status' => 'dead', 'delay' => 0);
        }
        return array(
            'status' => 'pending',
            'delay' => self::collaboration_retry_delay($attempts),
        );
    }

    private static function fail_collaboration_outbox_job(
        $job_id,
        $lease_token,
        $attempts,
        $error_code
    ) {
        if (!self::collaboration_phase1_enabled()) { return false; }
        global $wpdb;
        $tables = self::collaboration_tables();
        $state = self::collaboration_outbox_failure_state($attempts);
        $error_code = sanitize_key((string) $error_code);
        if (!$tables || !$error_code || strlen($error_code) > 80
            || !isset($wpdb) || !method_exists($wpdb, 'update')) {
            return false;
        }
        $next_timestamp = time() + (int) $state['delay'];
        $updated = $wpdb->update($tables['outbox'], array(
            'status' => (string) $state['status'],
            'next_attempt_at' => gmdate('Y-m-d H:i:s', $next_timestamp),
            'lease_token' => null,
            'lease_until' => null,
            'last_error_code' => $error_code,
            'updated_at' => gmdate('Y-m-d H:i:s'),
        ), array(
            'id' => (int) $job_id,
            'lease_token' => (string) $lease_token,
        ), array('%s', '%s', '%s', '%s', '%s', '%s'), array('%d', '%s'));
        if ($updated !== 1) { return false; }
        $job = $wpdb->get_row($wpdb->prepare(
            "SELECT request_id FROM {$tables['outbox']} WHERE id = %d LIMIT 1",
            (int) $job_id
        ), ARRAY_A);
        if (is_array($job) && (int) ($job['request_id'] ?? 0) > 0) {
            self::record_collaboration_audit(
                (int) $job['request_id'],
                'system',
                0,
                $state['status'] === 'dead' ? 'work_mail_dead' : 'work_mail_retry_scheduled',
                $state['status'] === 'dead' ? 'dead' : 'retry',
                array(
                    'channel' => 'work_mail',
                    'attempt' => (int) $attempts,
                    'errorCode' => $error_code,
                )
            );
        }
        if ($state['status'] === 'pending') {
            self::schedule_collaboration_outbox_job((int) $job_id, $next_timestamp);
        }
        return true;
    }

    private static function collaboration_work_email() {
        $configured = defined('YISHU_COLLABORATION_EMAIL')
            ? constant('YISHU_COLLABORATION_EMAIL')
            : self::COLLABORATION_EMAIL;
        $configured = apply_filters('yishu_collaboration_work_email', $configured);
        if (!is_scalar($configured)) { return ''; }
        $configured = (string) $configured;
        if ($configured === '' || preg_match('/[\r\n]/', $configured)) { return ''; }
        $configured = trim($configured);
        $configured = sanitize_email($configured);
        return $configured && is_email($configured) ? $configured : '';
    }

    private static function collaboration_mail_transport_ready() {
        // A callable wp_mail() only proves that WordPress loaded its wrapper;
        // it does not prove that an authenticated SMTP/transactional provider
        // is configured. Operations must explicitly attest both the transport
        // and recipient before either client capability can become visible.
        return self::collaboration_phase1_enabled()
            && defined('YISHU_COLLABORATION_MAIL_TRANSPORT_READY')
            && constant('YISHU_COLLABORATION_MAIL_TRANSPORT_READY') === true
            && defined('YISHU_COLLABORATION_EMAIL')
            && function_exists('wp_mail')
            && self::collaboration_work_email() !== '';
    }

    private static function collaboration_mail_body($job) {
        $labels = array(
            'drama' => '短剧 / 影视出演',
            'commercial' => '商业拍摄',
            'brand' => '品牌合作',
            'modeling' => '平面 / 模特',
            'event' => '活动出席',
            'other' => '其他合作',
        );
        $project_type = (string) ($job['project_type'] ?? 'other');
        $lines = array(
            '易姝合作邀约',
            '请求编号：' . (string) ($job['public_id'] ?? ''),
            '联系人：' . (string) ($job['contact_name'] ?? ''),
            '联系方式：' . (string) ($job['contact_method'] ?? ''),
            '公司 / 项目：' . (string) ($job['organization'] ?? ''),
            '合作类型：' . (string) ($labels[$project_type] ?? $labels['other']),
            '拍摄城市：' . (string) ($job['city'] ?? ''),
            '预计日期：' . (string) ($job['preferred_date'] ?? ''),
            '预算范围：' . (string) ($job['budget'] ?? ''),
            '',
            '项目说明：',
            (string) ($job['details'] ?? ''),
        );
        return implode("\n", $lines);
    }

}
