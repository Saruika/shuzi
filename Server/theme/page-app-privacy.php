<?php
/**
 * Public privacy policy required by App Store Review Guideline 5.1.1.
 * WordPress automatically selects this template for the app-privacy slug.
 */

defined('ABSPATH') || exit;
get_header();
?>

<style id="yishu-app-privacy-style">
    .yishu-app-privacy {
        width: min(860px, calc(100% - 36px));
        margin: 0 auto;
        padding: 132px 0 88px;
        color: rgba(255, 255, 255, 0.78);
        font-size: 16px;
        line-height: 1.9;
    }
    .yishu-app-privacy h2,
    .yishu-app-privacy h3 {
        color: #f6f1e7;
        font-family: "Noto Serif SC", serif;
        font-weight: 400;
        line-height: 1.35;
    }
    .yishu-app-privacy h2 {
        margin: 0 0 18px;
        font-size: clamp(32px, 7vw, 50px);
    }
    .yishu-app-privacy h3 {
        margin: 44px 0 12px;
        font-size: clamp(22px, 4vw, 29px);
    }
    .yishu-app-privacy p,
    .yishu-app-privacy li {
        max-width: 76ch;
    }
    .yishu-app-privacy ul {
        margin: 12px 0 0;
        padding-left: 1.35em;
    }
    .yishu-app-privacy li + li {
        margin-top: 10px;
    }
    .yishu-app-privacy strong,
    .yishu-app-privacy a {
        color: #d9b878;
    }
    .yishu-app-privacy a:focus-visible {
        outline: 2px solid #d9b878;
        outline-offset: 4px;
    }
    @media (max-width: 640px) {
        .yishu-app-privacy {
            width: min(100% - 30px, 860px);
            padding-top: 112px;
            font-size: 15px;
            line-height: 1.85;
        }
    }
</style>

<article class="yishu-app-privacy" aria-label="Hi，梳子 App 隐私政策">
    <?php
    while (have_posts()) {
        the_post();
        the_content();
    }
    ?>
</article>

<?php get_footer(); ?>
