# Nginx REST authentication

`shuzijun-rest-auth.conf` must be included inside the WordPress PHP FastCGI
location, after the standard FastCGI parameter include. Without it, PHP cannot
see the App's `Authorization` header and administrator login always fails.

The production servers currently use the equivalent inline directive. After
editing Nginx, run `nginx -t` before reloading the service.

`shuzijun-sensitive-files-deny.conf` must be included inside every TLS server
block that can read from the WordPress document root, before the generic PHP
and static-file locations. It returns 404 for `wp-config.php`, configuration or
source backups, editor swap files and similarly named residue. Backups belong
under a root-only directory outside the document root; blocking URLs is a
second boundary, not a substitute for moving the files.
