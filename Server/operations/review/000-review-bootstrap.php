<?php
/** Deployment-only isolation. Never install on the production WordPress site. */
defined('ABSPATH') || exit;
if (!defined('YISHU_APP_SERVICE_ENVIRONMENT') || YISHU_APP_SERVICE_ENVIRONMENT !== 'review'
    || ABSPATH !== '/srv/shuzijun-review/site/') {
    http_response_code(503);
    exit;
}
// No SMTP plugin, real contact messages, scheduled production jobs or external
// WordPress HTTP calls while this instance is in private bootstrap acceptance.
add_filter('pre_wp_mail', static function () { return false; }, PHP_INT_MAX);
add_filter('pre_http_request', static function () {
    return new WP_Error('review_bootstrap_offline', 'Review bootstrap has no external delivery.');
}, PHP_INT_MAX);
// The production theme normally registers this type. Keep the API's actual
// schema, approval and capability code unchanged without copying theme data.
add_action('init', static function () {
    register_post_type('portfolio', array(
        'label' => '审核演示相册', 'public' => false, 'show_ui' => false,
        'show_in_rest' => true, 'supports' => array('title', 'editor', 'thumbnail'),
    ));
});

