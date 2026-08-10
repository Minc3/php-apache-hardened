# php-apache-hardened

**Alpine 3.24 · Apache 2.4 · PHP 8.3, 8.4 or 8.5 · mod_php or php-fpm · 109–132 MB**

Source: [github.com/Minc3/php-apache-hardened](https://github.com/Minc3/php-apache-hardened) ·
Images: [hub.docker.com/r/menace100/php-apache-hardened](https://hub.docker.com/r/menace100/php-apache-hardened)

A hardened Apache + PHP image for running PHP applications behind a reverse
proxy. Runs as a non-root user (UID 33) on a read-only filesystem, with the
command-execution functions disabled and the filesystem confined.

The PHP version and the execution model are chosen by tag. Everything else you
can change is an environment variable — see [Configuration](#configuration).

```bash
docker run -d \
  -v /srv/mysite:/var/www/:ro \
  -v /srv/mysite/html/cache:/var/www/html/cache:rw \
  --user 33:33 \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -e TZ=Europe/London \
  menace100/php-apache-hardened:stable
```

---

## Tags

Every tag is the same hardening, the same mount layout and the same extension
set. Two things vary: the PHP major, and how PHP is executed.

| Tag | PHP | Execution | Notes |
|---|---|---|---|
| `8.3`, `stable` | 8.3 | mod_php | Oldest major Alpine still packages, so the widest application compatibility. |
| `8.4` | 8.4 | mod_php | |
| `8.5`, `latest` | 8.5 | mod_php | Newest; expect deprecation fatals in older code. |
| `8.3-fpm`, `stable-fpm` | 8.3 | php-fpm | |
| `8.4-fpm` | 8.4 | php-fpm | |
| `8.5-fpm`, `latest-fpm` | 8.5 | php-fpm | |

**`:latest` follows the highest PHP major Alpine ships** — today 8.5. Like
`:stable` it is resolved at build time, not hardcoded, so the day Alpine
packages a new major, `:latest` becomes that major. Pulling with no tag
therefore gives you the newest PHP, which an off-the-shelf application may not
support — see [Which PHP version](#which-php-version) below.

**`:stable` follows the lowest PHP major Alpine ships** — today 8.3. When Alpine
drops a major, `:stable` moves up to the next oldest on its own.

**Pin a major.** Both aliases change PHP version under you; `:8.3` stays on
8.3 but still picks up Alpine, Apache and PHP patch updates on each rebuild. To
pin an exact build, reference it by digest (`@sha256:…`). Use a version tag for
anything you care about and treat `:latest` as a convenience.

### Which PHP version

Newer PHP is faster and supported for longer, but off-the-shelf applications
frequently lag. Two things that actually bite:

- **8.4 added `mb_ucfirst()` to core.** Any application shipping its own
  unguarded `mb_ucfirst()` fatals with *"Cannot redeclare"*. Some forum and CMS
  software does exactly this.
- **8.5 turns more long-standing deprecations into errors.** Fine for code you
  control, risky for a vendor application you cannot patch.

Check what your application supports before moving up. Switching is a tag
change and a recreate, so testing one is cheap:

```bash
docker run --rm menace100/php-apache-hardened:8.5 php -v
```

---

## Which variant

|  | `:8.3` (mod_php) | `:8.3-fpm` (php-fpm) |
|---|---|---|
| Apache MPM | `prefork` | `event` |
| PHP runs | inside every Apache child | in a separate process pool |
| Concurrent connections | = `APACHE_MAX_REQUEST_WORKERS` (24) | = `APACHE_MAX_REQUEST_WORKERS` (256) |
| Concurrent PHP | the same 24 | `PHP_FPM_MAX_CHILDREN` (24), independent |
| Processes in container | 1 | 2 (supervised) |
| `.htaccess` `php_value` | works | **500 error** — see below |
| Slow-request backtraces | no | yes (`slowlog`) |

**PHP does not execute faster under FPM.** The same opcode runs under the same
OPcache, and a single request takes the same time. What changes is that
`mpm_prefork` gives *every connection* — a static image, an idle keepalive
socket, a slow client — its own Apache child carrying a full PHP interpreter at
60–90 MB resident. That is why the mod_php image caps out at 24: it is a memory
budget being spent as a connection limit.

Splitting them decouples the two numbers. Apache threads hold connections for a
few MB each, and only requests actually executing PHP occupy a worker. The
default FPM sizing serves **256 concurrent connections against 24 PHP workers**
in the same 2 GB.

**Pick mod_php if** your application ships `.htaccess` files with `php_value`
directives you cannot edit, or traffic is low enough that 24 concurrent
connections was never the constraint. It is one process, and it is simpler.

**Pick fpm if** you are hitting the connection ceiling, serve much static
content or slow clients from the container, or want `slowlog` and
`request_terminate_timeout` for diagnosing stalls.

Both are drop-in for the same site: same mounts, same UID, same PHP settings.
Moving between them is a tag change, a recreate, and — for fpm — one extra
`tmpfs` line.

> **Migrating to `-fpm`: read [`php_value` in `.htaccess`](#php_value-in-htaccess)
> first.** It is the one change that can take a working site down, and it does so
> with a 500 on every page rather than something subtle.

---

## Directory layout

Mount your project at **`/var/www/`**, with the web root in an **`html/`**
subdirectory:

```
/srv/mysite/            ->  /var/www/         mounted read-only
/srv/mysite/html/       ->  /var/www/html/    DocumentRoot
/srv/mysite/html/cache  ->  mounted read-write separately
```

This matches the `php:8.3-apache` convention. Anything kept beside `html/`
(`vendor/`, `config/`) is readable by PHP but never served over HTTP.

**If `html/` does not exist, Apache will not start.**

Apache listens on **port 80**.

---

## Configuration

Every setting is applied at container start, so a change needs only a recreate.
Defaults are the hardened values: run with no environment set and you get
exactly the behaviour described under [Hardening](#hardening).

### General — both variants

| Variable | Default | Purpose |
|---|---|---|
| `TZ` | `UTC` | System timezone **and** PHP `date.timezone`. |
| `REMOTE_IP_HEADER` | `CF-Connecting-IP` | Header carrying the real client IP. See [Client IP](#client-ip-behind-a-proxy). |
| `APACHE_SERVER_NAME` | `localhost` | `ServerName`. Used only for self-referential URLs; `UseCanonicalName` is `Off`, so `SERVER_NAME` still comes from the `Host` header. |
| `APACHE_LIMIT_REQUEST_BODY` | `34603008` | Max request body in bytes (33 MB). Keep above `PHP_POST_MAX_SIZE`, or large uploads are rejected with a 413 before PHP sees them. On `-fpm` see [the caveat below](#request-body-limits-on--fpm). |

### Apache sizing — mod_php tags only

| Variable | Default | Purpose |
|---|---|---|
| `APACHE_START_SERVERS` | `3` | Children forked at startup. |
| `APACHE_MIN_SPARE_SERVERS` | `3` | Idle children kept in reserve; below this Apache forks more. |
| `APACHE_MAX_SPARE_SERVERS` | `8` | Idle ceiling; above this Apache reaps. Keep it at or above `APACHE_MIN_SPARE_SERVERS` — prefork silently raises it to `MinSpareServers + 1` otherwise, with no warning. |
| `APACHE_MAX_REQUEST_WORKERS` | `24` | Hard concurrency cap. `ServerLimit` tracks this variable, so values above 256 actually take effect — stock Apache would clamp there. |
| `APACHE_MAX_CONNECTIONS_PER_CHILD` | `500` | Requests a child serves before it is recycled, so a slow leak in the application or an extension cannot accumulate for the life of the container. `0` disables recycling. |

> **`APACHE_MAX_REQUEST_WORKERS` is a memory budget, not a throughput dial.**
> `mpm_prefork` with mod_php gives every child its own interpreter, and a child
> serving a forum or store page sits at roughly 60–90 MB resident — so 24 is
> about what a 2048 MB container affords. Raise it only alongside the container
> memory limit, or you trade queueing for an OOM kill. Requests over the cap
> wait in the listen backlog, which degrades far more gracefully than either
> running out of memory or running the process table out. Watch the container
> `pids` limit too: every worker is a process, so the cap must clear
> `MaxRequestWorkers` plus the parent and the healthcheck `curl`.

### Apache sizing — `-fpm` tags only

These size the `event` MPM, which holds *connections*. They are no longer a
memory budget — that moved to `PHP_FPM_MAX_CHILDREN` below.

| Variable | Default | Purpose |
|---|---|---|
| `APACHE_START_SERVERS` | `2` | Child processes forked at startup; each runs `APACHE_THREADS_PER_CHILD` threads. |
| `APACHE_THREADS_PER_CHILD` | `64` | Connection-handling threads per child. |
| `APACHE_MAX_REQUEST_WORKERS` | `256` | Hard cap on concurrent connections. Rounded **up** to a multiple of `APACHE_THREADS_PER_CHILD`. |
| `APACHE_MIN_SPARE_THREADS` | `32` | Idle threads kept in reserve. |
| `APACHE_MAX_SPARE_THREADS` | `128` | Idle ceiling. |
| `APACHE_MAX_CONNECTIONS_PER_CHILD` | `0` | Off by default, unlike the mod_php image: Apache holds no interpreter here, so `PHP_FPM_MAX_REQUESTS` is what recycles the processes that run your code. |
| `APACHE_PROXY_TIMEOUT` | `90` | Seconds Apache waits on FPM. See the [timeout ladder](#timeouts). |

> **Do not set `APACHE_SERVER_LIMIT` or `APACHE_THREAD_LIMIT`.** The `event` MPM
> requires `ServerLimit ≥ MaxRequestWorkers ÷ ThreadsPerChild` and silently
> clamps to the smaller value when they disagree, so a raised worker count just
> quietly fails to take effect. The container computes both from the two
> variables above at start and overrides whatever the environment holds.

### PHP-FPM pool — `-fpm` tags only

| Variable | Default | Purpose |
|---|---|---|
| `PHP_FPM_MAX_CHILDREN` | `24` | **The memory budget.** Max requests executing PHP at once, at 60–90 MB each. Connections above this queue for a worker rather than failing. |
| `PHP_FPM_PM` | `dynamic` | `dynamic`, `ondemand` or `static`. |
| `PHP_FPM_START_SERVERS` | `3` | `dynamic` only. |
| `PHP_FPM_MIN_SPARE_SERVERS` | `3` | `dynamic` only. |
| `PHP_FPM_MAX_SPARE_SERVERS` | `8` | `dynamic` only. |
| `PHP_FPM_MAX_REQUESTS` | `500` | Requests a worker serves before it is recycled. `0` disables. |
| `PHP_FPM_REQUEST_TERMINATE_TIMEOUT` | `75` | Seconds before a stuck worker is killed. Must exceed `PHP_MAX_EXECUTION_TIME`. |
| `PHP_FPM_SLOWLOG_TIMEOUT` | `10s` | Requests slower than this are logged with a full PHP backtrace. `0` disables. |

### PHP limits — both variants

| Variable | Default | Purpose |
|---|---|---|
| `PHP_MEMORY_LIMIT` | `256M` | |
| `PHP_MAX_EXECUTION_TIME` | `60` | Seconds of PHP execution. |
| `PHP_POST_MAX_SIZE` | `32M` | Keep under `APACHE_LIMIT_REQUEST_BODY`. |
| `PHP_UPLOAD_MAX_FILESIZE` | `24M` | Keep under `PHP_POST_MAX_SIZE`. |
| `PHP_MAX_FILE_UPLOADS` | `20` | |

### PHP behaviour and hardening — both variants

| Variable | Default | Purpose |
|---|---|---|
| `PHP_ALLOW_URL_FOPEN` | `0` | `1` allows `file_get_contents("https://…")`. Off by default because it turns any attacker-controlled path into an SSRF primitive. |
| `PHP_DISPLAY_ERRORS` | `0` | `1` renders errors in the response. **Leaks paths, stack traces and credentials — never leave on in production.** |
| `PHP_OPEN_BASEDIR` | `/var/www:/tmp` | Filesystem confinement. Empty string removes it. |
| `PHP_DISABLE_FUNCTIONS` | see [Hardening](#hardening) | Comma-separated. Empty string re-enables everything. |

### OPcache — both variants

| Variable | Default | Purpose |
|---|---|---|
| `PHP_OPCACHE_ENABLE` | `1` | |
| `PHP_OPCACHE_MEMORY` | `128` | Megabytes. |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `1` | `0` is faster but needs a restart for code changes to appear — immutable deploys only. |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `2` | Seconds between file mtime checks. |

> **Booleans must be `0` or `1`, never `Off`/`On`.** These are injected by
> variable substitution, so PHP stores the literal string — `ini_get()` would
> return `"Off"`, which is *truthy* in PHP, and any application testing
> `if (ini_get('allow_url_fopen'))` takes the wrong branch.

> **Override these variables, never unset them.** An unset `${VAR}` is left as a
> literal string by Apache, PHP and PHP-FPM alike and fails silently — Apache
> would treat `${APACHE_SERVER_NAME}` as a hostname.

`allow_url_include`, `expose_php` and the security response headers are fixed
and cannot be relaxed.

### Timeouts

On the `-fpm` tags three timeouts stack, and they must stay in this order or a
slow request is reported at the wrong layer:

```
PHP_MAX_EXECUTION_TIME (60)  <  PHP_FPM_REQUEST_TERMINATE_TIMEOUT (75)  <  APACHE_PROXY_TIMEOUT (90)
        PHP gives up first          FPM kills a worker that ignored it       Apache gives up last
```

`max_execution_time` does not count time blocked in a database call or a socket
read, which is exactly where requests hang — `request_terminate_timeout` is what
actually ends those. If `APACHE_PROXY_TIMEOUT` drops below it, Apache returns a
504 while FPM is still working, and the log tells you nothing useful.

---

## Running it

### mod_php

```yaml
services:
  web:
    image: menace100/php-apache-hardened:stable
    restart: unless-stopped
    environment:
      - TZ=Europe/London

    volumes:
      - /srv/mysite:/var/www/:ro
      - /srv/mysite/html/cache:/var/www/html/cache:rw

    # www-data. Must match the UID owning your files on the host.
    user: '33:33'

    # Required to bind port 80 as a non-root user. cap_add: NET_BIND_SERVICE
    # does NOT work here - Docker grants no ambient capabilities to non-root.
    sysctls:
      - net.ipv4.ip_unprivileged_port_start=0

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /run/apache2:uid=33,gid=33,mode=0755,noexec,nosuid,nodev
      - /tmp:uid=33,gid=33,mode=1777,noexec,nosuid,nodev

    # APACHE_MAX_REQUEST_WORKERS defaults to 24, sized against this memory
    # limit. Change one and change the other; pids is only a backstop now,
    # not the binding constraint.
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: '2048M'
          pids: 256

    # Apache logs to stdout, so every access line becomes a host json-file
    # entry. Uncapped that grows until the disk is full. 30M holds enough
    # history to debug a recent incident.
    logging:
      driver: json-file
      options:
        max-size: '10m'
        max-file: '3'
```

### php-fpm

Identical, with **one extra tmpfs** for the FastCGI socket and the sizing
variables moved. Without `/run/php-fpm` the container cannot create its socket
and exits during startup.

```yaml
services:
  web:
    image: menace100/php-apache-hardened:stable-fpm
    restart: unless-stopped
    environment:
      - TZ=Europe/London

    volumes:
      - /srv/mysite:/var/www/:ro
      - /srv/mysite/html/cache:/var/www/html/cache:rw

    user: '33:33'
    sysctls:
      - net.ipv4.ip_unprivileged_port_start=0

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /run/apache2:uid=33,gid=33,mode=0755,noexec,nosuid,nodev
      - /run/php-fpm:uid=33,gid=33,mode=0755,noexec,nosuid,nodev   # <- required
      - /tmp:uid=33,gid=33,mode=1777,noexec,nosuid,nodev

    # PHP_FPM_MAX_CHILDREN (24) is the memory budget now, not the Apache
    # worker count - the 256 default connections are cheap by comparison.
    # pids is far less pressured here: 2 Apache children plus the FPM master
    # and its workers, rather than one process per connection.
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: '2048M'
          pids: 128

    logging:
      driver: json-file
      options:
        max-size: '10m'
        max-file: '3'
```

### UID 33

`www-data` is UID **33**, matching Debian and Ubuntu. Alpine's own `www-data` is
82, but bind mounts carry raw numeric IDs, so 82 would read as a foreign user
and Apache would fail with `EACCES` on your files.

If you see `(13)Permission denied … pcfg_openfile`, compare `ls -ln` on the host
against `id www-data` in the container. Names match across distributions;
numbers are what count.

On the `-fpm` tags you will see two startup notices saying the pool's `user`
and `group` directives are *ignored when FPM is not running as root*. That is
expected and correct — the container is already running as UID 33, so there is
nothing to drop to. The directives exist only so the image still works if run
as root, where FPM refuses to start without them.

### Writable paths

The root filesystem is read-only and your code is mounted `:ro`, so a
compromised PHP process cannot rewrite its own source. Mount each writable
directory explicitly. Anything writable inside the docroot can execute PHP if
something manages to write a `.php` into it, so keep the list short and prefer
storage outside the web root.

`/tmp` is tmpfs, so PHP sessions do not survive a restart. Use a database or
Redis session handler if that matters.

---

## Client IP, behind a proxy

`mod_remoteip` rewrites `REMOTE_ADDR` and the access log from
`REMOTE_IP_HEADER`, trusting only private and Cloudflare ranges. It also sets
`HTTPS=on` from `X-Forwarded-Proto`, so applications build `https://` URLs and
do not redirect-loop behind a TLS-terminating proxy.

The default is `CF-Connecting-IP` rather than `X-Forwarded-For`, because Traefik
only preserves an inbound `X-Forwarded-For` from peers listed in its
`forwardedHeaders.trustedIPs`. Cloudflare is not in that list by default, so
Traefik discards Cloudflare's header and substitutes the edge address — every
visitor then logs as a Cloudflare IP.

If you are not behind Cloudflare, or your proxy is configured to forward the
original header, set:

```yaml
environment:
  - REMOTE_IP_HEADER=X-Forwarded-For
```

`mod_remoteip` accepts exactly one header and cannot fall back to a second.

Cloudflare's ranges are baked in at build time. If they change, pull a newer
image.

---

## Hardening

**Apache** — 26 modules loaded on the mod_php tags, 27 on `-fpm` (`autoindex`,
`status`, `negotiation`, `userdir`, `info` and `cgi` removed),
`ServerTokens Prod`, `TraceEnable Off`, `FileETag None`, no directory listings.

On the `-fpm` tags, `apache2-proxy` ships nineteen proxy modules and all but
`mod_proxy` and `mod_proxy_fcgi` are disabled — including `mod_proxy_connect`,
a forward-proxy `CONNECT` handler. `ProxyRequests` is explicitly `Off`. That is
the whole difference in the module list: mod_php out, those two in.

**Response headers** — `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Permissions-Policy`,
and `X-Powered-By` removed.

**No Content-Security-Policy is set.** A strict default silently breaks payment
providers, embedded media and CDNs. Set one for your site in `html/.htaccess`.

**Never served** — dotfiles and dot-directories (`.git`, `.env`),
`composer.json`/`.lock`, `package.json`, and `*.env|ini|log|sh|sql|bak|swp|dist|tpl`.
`/.well-known/` is exempt so ACME challenges still work.

**PHP**

```
expose_php          Off        display_errors      Off
allow_url_include   Off        open_basedir        /var/www:/tmp
zend.exception_ignore_args     On   (keeps credentials out of stack traces)
```

`disable_functions`:

```
exec, passthru, shell_exec, system, proc_open, proc_close, proc_get_status,
proc_nice, proc_terminate, popen, pcntl_exec, pcntl_fork, dl, show_source,
highlight_file
```

The backtick operator is covered too — it routes through `shell_exec`.

`putenv`, `symlink`, `link` and `php_uname` are deliberately left **enabled**:
real applications reference all four, and disabling them causes fatal errors
rather than protection.

> `disable_functions` is a PHP-level control. A native bug in PHP or an
> extension is not bound by it — `cap_drop`, `no-new-privileges` and the
> read-only root filesystem cover that layer.

`.htaccess` is enabled (`AllowOverride All`) and `mod_rewrite` is available, so
front-controller rewrites work.

### FastCGI request forgery — `-fpm` tags

Handing `.php` to a FastCGI backend introduces a failure mode mod_php does not
have: a naive `SetHandler` forwards anything whose path merely *contains* `.php`
to the interpreter, so `/uploads/avatar.jpg/x.php` reaches PHP and `PATH_INFO`
decides what actually executes. Three independent layers close it:

1. Apache only sets the FastCGI handler when the resolved filename is a real
   file (`<If "-f %{REQUEST_FILENAME}">`).
2. `cgi.fix_pathinfo = 0`, so PHP will not guess at a script the server did not
   name.
3. `security.limit_extensions = .php` in the pool, so FPM refuses anything else
   whatever Apache asks for.

`/index.php/nonexistent.php` and `/nope.php` both return 404 without the socket
being touched.

### Request body limits on `-fpm`

`LimitRequestBody` is enforced by whatever reads the request body. mod_php reads
it through Apache and the limit applies; `mod_proxy_fcgi` streams the body to
the socket itself and never consults it. Left alone, `APACHE_LIMIT_REQUEST_BODY`
would silently stop applying to PHP requests on the `-fpm` tags — a 2000-byte
body against a 1000-byte limit is a 413 on mod_php and was a 200 here.

The `-fpm` image therefore rejects oversized requests on the declared
`Content-Length` before the handler runs, restoring the 413. **One residual
difference remains:** a body sent with `Transfer-Encoding: chunked` carries no
`Content-Length`, so it is capped by PHP's `post_max_size` rather than by
Apache. mod_php catches that case; this does not, and no amount of Apache
configuration changes it. Uploads are still bounded — just one layer later.

Static files are unaffected: they are served by the core handler, so
`LimitRequestBody` applies to them normally on both variants, chunked included.

---

## PHP extensions

```
bcmath  ctype  curl  dom  exif  fileinfo  gd  iconv  intl  mbstring  mysqli
opcache  openssl  pdo  pdo_mysql  session  simplexml  sodium  tokenizer  xml
xmlreader  xmlwriter  zip  zlib
```

Deliberately excluded: `phar` (deserialization vector), `posix`, `pcntl`, `ftp`,
`sockets`, `soap`, `imagick`, `redis`, `memcached`.

---

## Healthcheck

Every 30 seconds, three consecutive failures mark the container `unhealthy`.

```bash
docker inspect <container> --format '{{.State.Health.Status}}'
```

**mod_php tags** probe `/` with `curl -f`. Note this executes your
application's full stack, including database and outbound calls.

**`-fpm` tags** probe `/fpm-ping`, which PHP-FPM answers itself with `pong`
before any application code is reached — so the probe still proves Apache is
serving *and* the FastCGI socket answers, without running ~2,880 sets of
database queries a day. The path is aliased outside the docroot so a
front-controller `.htaccess` cannot capture it, and is restricted to genuine
loopback: the check uses `CONN_REMOTE_ADDR`, not `REMOTE_ADDR`, so a request
arriving through the trusted proxy carrying `CF-Connecting-IP: 127.0.0.1`
cannot reach it. From off-box it returns 403.

Probes are excluded from the access log — they would otherwise add roughly 2,880
lines a day. Exclusion requires *both* a loopback origin and the
`docker-healthcheck` user-agent, so setting that user-agent from outside does
not hide a request. Errors a probe triggers still reach the error log.

On the `-fpm` tags a supervisor sits at PID 1 and takes the container down if
*either* Apache or PHP-FPM dies, so `restart: unless-stopped` recovers it. A
dead FPM would otherwise leave Apache serving 503s indefinitely.

---

## Migrating to `-fpm`

### `php_value` in `.htaccess`

**This is the one thing that will break a working site.** `php_value`,
`php_flag`, `php_admin_value` and `php_admin_flag` are directives *provided by
mod_php*. With mod_php gone, Apache does not recognise them and returns
**HTTP 500 for every request in that directory tree**, logging:

```
Invalid command 'php_value', perhaps misspelled or defined by a module not
included in the server configuration
```

Applications and hosting guides add these constantly — usually
`memory_limit`, `upload_max_filesize` or `max_execution_time`.

Check before you switch:

```bash
grep -rniE '^\s*php_(value|flag|admin_value|admin_flag)' /srv/mysite/html
```

Three ways to fix each hit:

- **Delete it and set the equivalent environment variable** (`PHP_MEMORY_LIMIT`
  and friends) — best, since the setting then lives with the deployment.
- **Wrap it** in `<IfModule mod_php.c> … </IfModule>`, which makes Apache skip
  the block silently. The setting stops applying — this only avoids the 500.
- **Stay on the mod_php tag.**

### PATH_INFO routing

URLs of the form `/index.php/controller/action` return 404 on the `-fpm` tags,
and there is deliberately no switch to re-enable them — dropping the guard does
not bring them back either, it only turns the 404 into a 403 from
`security.limit_extensions`. Making them work needs `ProxyFCGISetEnvIf`
rewriting of `SCRIPT_FILENAME`, which is precisely where FastCGI path
vulnerabilities live.

Front-controller rewrites are unaffected — WordPress, IPS, Laravel and Magento
all resolve to a real file via `mod_rewrite` before the handler is chosen.

### Everything that does *not* change

- Mounts, `html/` layout, UID 33, read-only root, `cap_drop`, sysctls.
- Every `PHP_*` limit and hardening variable, `.htaccess` rewrites, and
  `AllowOverride All`.
- **Environment variables remain visible to PHP.** FPM clears the environment
  for workers by default, which would make `getenv('DB_PASS')` and `$_ENV` come
  back empty; the pool sets `clear_env = no` to match mod_php.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `(13)Permission denied … pcfg_openfile` | Host files not readable by UID 33. Compare `ls -ln` with the container's `id www-data`. |
| `DocumentRoot … is not a directory` | No `html/` inside the mounted directory. |
| App 500s with `mkdir(): Read-only file system` | A writable path is not mounted `:rw`. |
| Every visitor logs as a proxy IP | Wrong `REMOTE_IP_HEADER` for your proxy, or the proxy is overwriting the header. |
| Uploads rejected with 413 | `APACHE_LIMIT_REQUEST_BODY` is below `PHP_POST_MAX_SIZE`. |
| A settings change has no effect | The container was not recreated. `docker compose up -d --force-recreate`. |
| `TZ` appears ignored | Check the variable reached the container: `docker exec <c> printenv TZ`. |
| **`-fpm`:** every page 500s, log says `Invalid command 'php_value'` | An `.htaccess` uses mod_php directives. See [above](#php_value-in-htaccess). |
| **`-fpm`:** container exits at startup, `php-fpm never created /run/php-fpm/www.sock` | The `/run/php-fpm` tmpfs is missing from the compose file. |
| **`-fpm`:** `/index.php/foo` returns 404 | PATH_INFO routing, [not supported](#path_info-routing). |
| **`-fpm`:** raising `APACHE_MAX_REQUEST_WORKERS` changes nothing | It rounds up to a multiple of `APACHE_THREADS_PER_CHILD`; raise that instead for large jumps. |
| **`-fpm`:** requests queue while CPU and memory are idle | `PHP_FPM_MAX_CHILDREN`, not the Apache worker count, is the PHP concurrency limit. |
| **`-fpm`:** `is not a valid number (greater or equal than zero)` | A pool setting was written `$VAR` instead of `${VAR}`. PHP-FPM only expands the braced form. |

Config can be validated against an image without starting it:

```bash
docker run --rm --entrypoint httpd    menace100/php-apache-hardened:stable-fpm -t
docker run --rm --entrypoint php-fpm  menace100/php-apache-hardened:stable-fpm -t
```

---

## Tests

`./test.sh` is a behavioural suite over both variants and every PHP major.
`build-all.sh` already answers *can this image serve a bind-mounted site,
read-only, as UID 33* before it publishes anything; this answers the other
question — **does every variable in this README actually do what it says?** A
variable that is declared but never wired reads exactly like one that works.

```bash
./test.sh                    # everything: both variants, every major
./test.sh --php 8.3          # one major
./test.sh --variant fpm      # one variant (fpm | modphp)
./test.sh --no-build         # reuse images already built locally
./test.sh --image REF        # test one specific image (needs --variant)
./test.sh --keep             # leave containers behind for inspection
./test.sh --quiet            # only failures and the summary
```

Two passes over each image, both running it exactly as documented above —
non-root, read-only root filesystem, tmpfs for the writable paths:

- **defaults** — no `-e` flags at all, asserting the hardened values promised
  to anyone who runs the image with no configuration: every PHP limit,
  `open_basedir`, `disable_functions` (checked by calling `function_exists`,
  not by reading the string back), the response headers, the deny rules.
- **custom** — every documented variable set to something that is *not* the
  default, asserting each one took effect. `PHP_DISABLE_FUNCTIONS=exec,system`
  has to genuinely re-enable `passthru` while leaving `exec` gone;
  `REMOTE_IP_HEADER` is asserted from a second container; `allow_url_include`
  and `expose_php` must stay off no matter what the environment says.

The `-fpm` images additionally cover the FastCGI path guard, the request-body
limit, `/fpm-ping` being refused from off-box even by a client asserting
loopback through the trusted proxy header, the `ServerLimit` arithmetic, and
the supervisor — each process is killed in turn to confirm the container
actually stops rather than serving 503s, and a normal `docker stop` still exits
0 gracefully.

Exit status is 0 when everything passes and 1 otherwise, so it works as a gate:

```bash
./test.sh && ./build-all.sh
```

A full run builds six images and starts around forty short-lived containers —
budget ten minutes cold, less with a warm build cache.

---

## Building and updates

Images are built from two Dockerfiles — `Dockerfile` (mod_php) and
`Dockerfile.fpm` — by `build-all.sh`, which discovers the PHP majors Alpine
ships rather than hardcoding them. A new major becomes a tag on the next run
with no edit, in both variants.

```bash
./build-all.sh                  # rebuild + push only what is stale, both variants
./build-all.sh --check          # report only (exit 10 = work to do)
./build-all.sh --force          # rebuild every major regardless
./build-all.sh --no-push        # build and smoke test only
./build-all.sh --php 8.4        # restrict to one major
./build-all.sh --variant fpm    # restrict to one variant (fpm | modphp)
./build-all.sh --list           # show what would be built
```

Each variant is probed against Alpine separately — for `php*-apache2` and
`php*-fpm` respectively — so a major packaged for one and not the other simply
does not get that tag.

Nothing inside a container auto-updates: packages are frozen at build time. The
script asks each **published** tag what it would upgrade, and rebuilds only the
majors where something actually moved — a new Alpine package, or a new base
image digest recorded as a `base.digest` label at build time. A run with nothing
to do takes a few seconds and pushes nothing, so it is safe to run daily:

```
20 4 * * * /path/to/build-all.sh >> /var/log/php-apache-hardened.log 2>&1
```

Cron needs `docker login` as the user it runs as, and a `PATH` that includes
`docker`. Each major and variant is built and tested independently — one broken
combination is skipped and reported rather than blocking the rest, and anything
that fails its smoke test is never tagged or pushed.

The smoke test runs each image the way the README documents it — non-root,
read-only root filesystem, tmpfs for the writable paths — and asserts that PHP
executes, that `php_sapi_name()` is the one the variant is supposed to use, that
`/.env` is refused with a 403, and that an orphan `PATH_INFO` request 404s. The
`-fpm` images additionally have both configs validated and `/fpm-ping` checked.

Editing a Dockerfile does **not** trigger a rebuild; the check only looks at
package versions. Use `--force` — and `./test.sh` before you push, since the
smoke test covers "it serves PHP", not "every setting still behaves".

---

## Notes

- mod_php tags run `mpm_prefork`; `-fpm` tags run `mpm_event` with PHP-FPM over
  a unix socket at `/run/php-fpm/www.sock`.
- All PHP majors are built from one Dockerfile per variant via a `PHP_VER`
  build argument; the published tags are produced by `build-all.sh`, which
  discovers the majors Alpine ships rather than hardcoding them.
- The access log uses `%a`, so it shows the resolved client, not the proxy.
- Nothing inside the container auto-updates. Pull a newer image for security
  fixes to Alpine, Apache and PHP.
