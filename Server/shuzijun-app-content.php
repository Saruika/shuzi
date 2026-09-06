<?php
/**
 * Plugin Name: Shuzijun App Content API
 * Description: Versioned access-controlled content feed and least-privilege mobile publishing API for the Yi Shu app.
 * Version: 1.5.13.5
 * Author: Shuzijun
 */

defined('ABSPATH') || exit;

require_once __DIR__ . '/vendor/shuzijun/app-content/class-shuzijun-app-content-api.php';

Shuzijun_App_Content_API::init();
