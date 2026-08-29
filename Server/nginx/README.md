# Nginx REST authentication

`shuzijun-rest-auth.conf` must be included inside the WordPress PHP FastCGI
location, after the standard FastCGI parameter include. Without it, PHP cannot
see the App's `Authorization` header and administrator login always fails.

The production servers currently use the equivalent inline directive. After
editing Nginx, run `nginx -t` before reloading the service.
