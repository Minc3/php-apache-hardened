# php-apache-hardened

Hardened **Apache + PHP** for running off-the-shelf PHP applications behind a
reverse proxy. Non-root (UID 33), read-only filesystem, command-execution
functions disabled, filesystem confined.

Alpine 3.24 · Apache 2.4 · PHP 8.3 / 8.4 / 8.5 · mod_php or php-fpm · 109–132 MB

📖 **Full documentation:** https://github.com/Minc3/php-apache-hardened

---

## Tags

| Tag | PHP | Execution |
|---|---|---|
| `8.3`, `stable` | 8.3 | mod_php |
| `8.4` | 8.4 | mod_php |
| `8.5`, `latest` | 8.5 | mod_php |
| `8.3-fpm`, `stable-fpm` | 8.3 | php-fpm |
| `8.4-fpm` | 8.4 | php-fpm |
| `8.5-fpm`, `latest-fpm` | 8.5 | php-fpm |

`:stable` tracks the **oldest** PHP major Alpine ships (widest app support),
`:latest` the **newest**. Both move on their own — pin `:8.3` for anything you
care about.

---

## Quick start

```bash
docker run -d \
  -v /srv/mysite:/var/www/:ro \
  -v /srv/mysite/html/cache:/var/www/html/cache:rw \
  --user 33:33 \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -e TZ=Europe/London \
  menace100/php-apache-hardened:stable
```

**Mount your project at `/var/www/`, with the web root in an `html/`
subdirectory.** If `html/` does not exist, Apache will not start.

```
/srv/mysite/           ->  /var/www/        mounted read-only
/srv/mysite/html/      ->  /var/www/html/   DocumentRoot
```

Anything beside `html/` (`vendor/`, `config/`) is readable by PHP but never
served over HTTP. Apache listens on **port 80**.

---

## Which variant

|  | mod_php | php-fpm |
|---|---|---|
| Apache MPM | `prefork` | `event` |
| Concurrent connections | 24 | 256 |
| Concurrent PHP | the same 24 | 24, independent |
| `.htaccess` `php_value` | works | **500 error** |
| Slow-request backtraces | no | yes |

**PHP is not faster under FPM** — the same opcode, the same OPcache. What
changes is that `prefork` gives *every* connection its own Apache child
carrying a full interpreter (60–90 MB), so concurrency and memory are the same
number. Splitting them decouples the two: the default FPM sizing serves 256
concurrent connections against 24 PHP workers in the same 2 GB.

Use **mod_php** if traffic is modest or your app ships `php_value` directives
you cannot edit. Use **`-fpm`** if you are hitting the connection ceiling, serve
lots of static content, or want `slowlog` for diagnosing stalls.

---

## docker-compose

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

    user: '33:33'
    sysctls:
      - net.ipv4.ip_unprivileged_port_start=0

    security_opt: [ 'no-new-privileges:true' ]
    cap_drop: [ ALL ]
    read_only: true
    tmpfs:
      - /run/apache2:uid=33,gid=33,mode=0755,noexec,nosuid,nodev
      - /tmp:uid=33,gid=33,mode=1777,noexec,nosuid,nodev

    deploy:
      resources:
        limits: { cpus: '2', memory: '2048M', pids: 256 }

    logging:
      driver: json-file
      options: { max-size: '10m', max-file: '3' }
```

### php-fpm

Identical, plus **one extra tmpfs** for the FastCGI socket. Without
`/run/php-fpm` the container cannot create its socket and exits at startup.

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

    security_opt: [ 'no-new-privileges:true' ]
    cap_drop: [ ALL ]
    read_only: true
    tmpfs:
      - /run/apache2:uid=33,gid=33,mode=0755,noexec,nosuid,nodev
      - /run/php-fpm:uid=33,gid=33,mode=0755,noexec,nosuid,nodev   # required
      - /tmp:uid=33,gid=33,mode=1777,noexec,nosuid,nodev

    deploy:
      resources:
        limits: { cpus: '2', memory: '2048M', pids: 128 }

    logging:
      driver: json-file
      options: { max-size: '10m', max-file: '3' }
```

---

## Configuration

Everything is an environment variable, applied at container start — a change
needs only a recreate. Defaults are the hardened values.

**Common**

| Variable | Default |
|---|---|
| `TZ` | `UTC` |
| `REMOTE_IP_HEADER` | `CF-Connecting-IP` |
| `APACHE_SERVER_NAME` | `localhost` |
| `APACHE_LIMIT_REQUEST_BODY` | `34603008` |
| `PHP_MEMORY_LIMIT` | `256M` |
| `PHP_MAX_EXECUTION_TIME` | `60` |
| `PHP_POST_MAX_SIZE` | `32M` |
| `PHP_UPLOAD_MAX_FILESIZE` | `24M` |
| `PHP_ALLOW_URL_FOPEN` | `0` |
| `PHP_DISPLAY_ERRORS` | `0` |
| `PHP_OPEN_BASEDIR` | `/var/www:/tmp` |
| `PHP_DISABLE_FUNCTIONS` | see below |
| `PHP_OPCACHE_ENABLE` / `_MEMORY` | `1` / `128` |

**mod_php sizing:** `APACHE_START_SERVERS` `3`,
`APACHE_MIN_SPARE_SERVERS` `3`, `APACHE_MAX_SPARE_SERVERS` `8`,
`APACHE_MAX_REQUEST_WORKERS` `24`, `APACHE_MAX_CONNECTIONS_PER_CHILD` `500`

**php-fpm sizing:** `APACHE_START_SERVERS` `2`,
`APACHE_THREADS_PER_CHILD` `64`, `APACHE_MAX_REQUEST_WORKERS` `256`,
`APACHE_MIN_SPARE_THREADS` `32`, `APACHE_MAX_SPARE_THREADS` `128`,
`APACHE_MAX_CONNECTIONS_PER_CHILD` `0`, `APACHE_PROXY_TIMEOUT` `90`,
`PHP_FPM_PM` `dynamic`, `PHP_FPM_MAX_CHILDREN` `24`,
`PHP_FPM_START_SERVERS` `3`, `PHP_FPM_MIN_SPARE_SERVERS` `3`,
`PHP_FPM_MAX_SPARE_SERVERS` `8`, `PHP_FPM_MAX_REQUESTS` `500`,
`PHP_FPM_REQUEST_TERMINATE_TIMEOUT` `75`, `PHP_FPM_SLOWLOG_TIMEOUT` `10s`

Note the three `APACHE_*` names shared with mod_php have **different defaults
per variant** — `START_SERVERS`, `MAX_REQUEST_WORKERS` and
`MAX_CONNECTIONS_PER_CHILD` above are the `-fpm` values.

> **Booleans must be `0` or `1`, never `Off`/`On`** — they are injected by
> variable substitution, so PHP would store the literal string `"Off"`, which is
> *truthy*. **Override variables, never unset them.**

> **The memory budget** is `APACHE_MAX_REQUEST_WORKERS` on mod_php and
> `PHP_FPM_MAX_CHILDREN` on `-fpm`: roughly 60–90 MB per concurrent PHP
> request. Raise it only alongside the container memory limit.

Full table, including every variable and its rationale, is on
[GitHub](https://github.com/Minc3/php-apache-hardened).

---

## Hardening

- Runs as **UID 33** (`www-data`, matching Debian/Ubuntu) on a **read-only**
  root filesystem, `cap_drop: ALL`, `no-new-privileges`.
- Apache: unnecessary modules removed, `ServerTokens Prod`, `TraceEnable Off`,
  `FileETag None`, no directory listings.
- Headers: `X-Content-Type-Options`, `X-Frame-Options: DENY`,
  `Referrer-Policy`, `Permissions-Policy`; `X-Powered-By` removed.
- Never served: dotfiles and dot-directories (`.git`, `.env`),
  `composer.json`/`.lock`, `package.json`, `*.env|ini|log|sh|sql|bak|swp|dist|tpl`
  (`/.well-known/` stays reachable for ACME).
- PHP: `expose_php` Off, `display_errors` Off, `allow_url_include` Off,
  `open_basedir` confined, and `disable_functions`:
  `exec, passthru, shell_exec, system, proc_open, proc_close, proc_get_status,
  proc_nice, proc_terminate, popen, pcntl_exec, pcntl_fork, dl, show_source,
  highlight_file`
- `.htaccess` (`AllowOverride All`) and `mod_rewrite` remain enabled, so
  front-controller rewrites work.
- `-fpm` additionally guards the FastCGI path (`cgi.fix_pathinfo=0`,
  `security.limit_extensions=.php`, and Apache only handing over real files),
  and supervises both processes so either dying stops the container.

**Extensions:** `bcmath ctype curl dom exif fileinfo gd iconv intl mbstring
mysqli opcache openssl pdo pdo_mysql session simplexml sodium tokenizer xml
xmlreader xmlwriter zip zlib`

Excluded on purpose: `phar`, `posix`, `pcntl`, `ftp`, `sockets`, `soap`.

---

## Gotchas

| Symptom | Cause |
|---|---|
| `(13)Permission denied … pcfg_openfile` | Host files not readable by UID 33. Compare `ls -ln` with `id www-data`. |
| `DocumentRoot … is not a directory` | No `html/` inside the mounted directory. |
| `mkdir(): Read-only file system` | A writable path is not mounted `:rw`. |
| Uploads rejected with 413 | `APACHE_LIMIT_REQUEST_BODY` below `PHP_POST_MAX_SIZE`. |
| Every visitor logs as a proxy IP | Wrong `REMOTE_IP_HEADER`. Not behind Cloudflare? Set `X-Forwarded-For`. |
| A settings change does nothing | Recreate the container: `docker compose up -d --force-recreate`. |
| **`-fpm`:** every page 500s, `Invalid command 'php_value'` | An `.htaccess` uses mod_php directives — see below. |
| **`-fpm`:** exits with `entrypoint: /run/php-fpm is not writable` | The `/run/php-fpm` tmpfs is missing — the error prints the exact line to add. |
| **`-fpm`:** `/index.php/foo` returns 404 | PATH_INFO routing is not supported; rewrites are. |

### Migrating to `-fpm`: check your `.htaccess` first

`php_value` and friends are provided *by mod_php*. Without it Apache returns
**HTTP 500 for every request in that directory tree**. Check before switching:

```bash
grep -rniE '^\s*php_(value|flag|admin_value|admin_flag)' /srv/mysite/html
```

Fix each hit by deleting it and setting the equivalent `PHP_*` environment
variable, or by wrapping it in `<IfModule mod_php.c> … </IfModule>`.

Environment variables stay visible to PHP (`getenv()`, `$_ENV`) on both
variants.

---

## Healthcheck

mod_php probes `/`; `-fpm` probes an internal FPM ping that proves both Apache
and the FastCGI socket are alive **without executing your application**.

```bash
docker inspect <container> --format '{{.State.Health.Status}}'
```

---

Nothing inside the container auto-updates — pull a newer image for Alpine,
Apache and PHP security fixes.

**Source, full docs and the test suite:**
https://github.com/Minc3/php-apache-hardened
