# php-apache-hardened

**Alpine 3.24 · Apache 2.4 · PHP 8.3, 8.4 or 8.5 · 110–125 MB**

Source: [github.com/Minc3/php-apache-hardened](https://github.com/Minc3/php-apache-hardened) ·
Images: [hub.docker.com/r/menace100/php-apache-hardened](https://hub.docker.com/r/menace100/php-apache-hardened)

A hardened Apache + PHP image for running PHP applications behind a reverse
proxy. Runs as a non-root user (UID 33) on a read-only filesystem, with the
command-execution functions disabled and the filesystem confined.

The PHP version is chosen by tag. Everything else you can change is an
environment variable — see [Configuration](#configuration).

```bash
docker run -d \
  -v /srv/mysite:/var/www/:ro \
  -v /srv/mysite/html/cache:/var/www/html/cache:rw \
  --user 33:33 \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -e TZ=Europe/London \
  menace100/php-apache-hardened:8.3
```

---

## Tags

| Tag | PHP | Notes |
|---|---|---|
| `8.3`, `stable` | 8.3 | Oldest major Alpine still packages, so the widest application compatibility. |
| `8.4` | 8.4 | |
| `8.5`, `latest` | 8.5 | Newest; expect deprecation fatals in older code. |

Every tag is the same image and the same hardening — only the PHP major
differs. Apache, the extension set and every environment variable behave
identically across all of them.

**`:latest` follows the highest PHP major Alpine ships** — today 8.5. Like
`:stable` it is resolved at build time, not hardcoded, so the day Alpine
packages a new major, `:latest` becomes that major. Pulling with no tag
therefore gives you the newest PHP, which an off-the-shelf application may not
support — see [Which one](#which-one) below.

**`:stable` follows the lowest PHP major Alpine ships** — today 8.3. When Alpine
drops a major, `:stable` moves up to the next oldest on its own.

**Pin a major.** Both aliases change PHP version under you; `:8.3` stays on
8.3 but still picks up Alpine, Apache and PHP patch updates on each rebuild. To
pin an exact build, reference it by digest (`@sha256:…`). Use a version tag for
anything you care about and treat `:latest` as a convenience.

### Which one

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

### General

| Variable | Default | Purpose |
|---|---|---|
| `TZ` | `UTC` | System timezone **and** PHP `date.timezone`. |
| `REMOTE_IP_HEADER` | `CF-Connecting-IP` | Header carrying the real client IP. See [Client IP](#client-ip-behind-a-proxy). |

### Apache

| Variable | Default | Purpose |
|---|---|---|
| `APACHE_SERVER_NAME` | `localhost` | `ServerName`. Used only for self-referential URLs; `UseCanonicalName` is `Off`, so `SERVER_NAME` still comes from the `Host` header. |
| `APACHE_LIMIT_REQUEST_BODY` | `34603008` | Max request body in bytes (33 MB). Keep above `PHP_POST_MAX_SIZE`, or large uploads are rejected with a 413 before PHP sees them. |

### PHP limits

| Variable | Default | Purpose |
|---|---|---|
| `PHP_MEMORY_LIMIT` | `256M` | |
| `PHP_MAX_EXECUTION_TIME` | `60` | Seconds. Caps how long a stuck request holds a prefork worker. |
| `PHP_POST_MAX_SIZE` | `32M` | Keep under `APACHE_LIMIT_REQUEST_BODY`. |
| `PHP_UPLOAD_MAX_FILESIZE` | `24M` | Keep under `PHP_POST_MAX_SIZE`. |
| `PHP_MAX_FILE_UPLOADS` | `20` | |

### PHP behaviour and hardening

| Variable | Default | Purpose |
|---|---|---|
| `PHP_ALLOW_URL_FOPEN` | `0` | `1` allows `file_get_contents("https://…")`. Off by default because it turns any attacker-controlled path into an SSRF primitive. |
| `PHP_DISPLAY_ERRORS` | `0` | `1` renders errors in the response. **Leaks paths, stack traces and credentials — never leave on in production.** |
| `PHP_OPEN_BASEDIR` | `/var/www:/tmp` | Filesystem confinement. Empty string removes it. |
| `PHP_DISABLE_FUNCTIONS` | see [Hardening](#hardening) | Comma-separated. Empty string re-enables everything. |

### OPcache

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
> literal string by both Apache and PHP and fails silently — Apache would treat
> `${APACHE_SERVER_NAME}` as a hostname.

`allow_url_include`, `expose_php` and the security response headers are fixed
and cannot be relaxed.

---

## Running it

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

    # Apache logs to stdout, so every access line becomes a host json-file
    # entry. Uncapped that grows until the disk is full. 30M holds enough
    # history to debug a recent incident.
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

**Apache** — 26 modules loaded (`autoindex`, `status`, `negotiation`, `userdir`,
`info` and `cgi` removed), `ServerTokens Prod`, `TraceEnable Off`,
`FileETag None`, no directory listings.

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

Every 30 seconds, `curl -f` against `/` from inside the container. Three
consecutive failures mark it `unhealthy`.

```bash
docker inspect <container> --format '{{.State.Health.Status}}'
```

Probes are excluded from the access log — they would otherwise add roughly 2,880
lines a day. Exclusion requires *both* a loopback origin and the
`docker-healthcheck` user-agent, so setting that user-agent from outside does
not hide a request. Errors a probe triggers still reach the error log.

Note the probe executes your application's full stack, including database and
outbound calls.

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

---

## Building and updates

Images are built from one Dockerfile by `build-all.sh`, which discovers the PHP
majors Alpine ships rather than hardcoding them — a new major becomes a tag on
the next run with no edit.

```bash
./build-all.sh              # rebuild + push only what is stale
./build-all.sh --check      # report only (exit 10 = work to do)
./build-all.sh --force      # rebuild every major regardless
./build-all.sh --no-push    # build and smoke test only
./build-all.sh --php 8.4    # restrict to one major
./build-all.sh --list       # show what would be built
```

Nothing inside a container auto-updates: packages are frozen at build time. The
script asks each **published** tag what it would upgrade, and rebuilds only the
majors where something actually moved — a new Alpine package, or a new base
image digest recorded as a `base.digest` label at build time. A run with nothing
to do takes a few seconds and pushes nothing, so it is safe to run daily:

```
20 4 * * * /path/to/build-all.sh >> /var/log/php-apache-hardened.log 2>&1
```

Cron needs `docker login` as the user it runs as, and a `PATH` that includes
`docker`. Each major is built and tested independently — one broken version is
skipped and reported rather than blocking the rest, and a version that fails its
smoke test is never tagged or pushed.

Editing the Dockerfile does **not** trigger a rebuild; the check only looks at
package versions. Use `--force`.

---

## Notes

- Apache runs `mpm_prefork` with mod_php.
- All PHP majors are built from one Dockerfile via a `PHP_VER` build
  argument; the published tags are produced by `build-all.sh`, which
  discovers the majors Alpine ships rather than hardcoding them.
- The access log uses `%a`, so it shows the resolved client, not the proxy.
- Nothing inside the container auto-updates. Pull a newer image for security
  fixes to Alpine, Apache and PHP.
