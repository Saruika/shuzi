# StoreKit entitlement verifier

This localhost-only service verifies the signed StoreKit 2 transaction sent by
the iOS app. WordPress calls it with a separate internal token; neither the JWS
nor the token is logged.

Before enabling it in production:

1. Create the monthly subscription in App Store Connect and record the numeric
   App Apple ID.
2. Download the current Apple PKI root certificates from Apple and place their
   DER `.cer` files in `/etc/yishu/apple-roots`.
3. Create the `yishu-verifier` system user, virtual environment and a root-owned
   `/etc/yishu/entitlement-verifier.env` with mode `0600`.
4. Install `requirements.txt`, enable the systemd unit, and confirm that
   `http://127.0.0.1:8751/healthz` returns `{"ok":true}`.
5. Add `YISHU_ENTITLEMENT_VERIFIER_URL` and
   `YISHU_ENTITLEMENT_VERIFIER_TOKEN` to `wp-config.php`. The URL should be
   `http://127.0.0.1:8751/v1/verify` and the token must match the service env.

The Apple library is constrained to version 3.1.2 or later because earlier
versions are affected by the stale-OCSP-response verification advisory.
