FROM alpine:3.24

# PHP major version. Alpine 3.24 carries 83, 84 and 85 with full extension
# parity for the set below (opcache is the one exception - see 1a). Override:
#   docker build --build-arg PHP_VER=85 -t php-apache:85 .
ARG PHP_VER=83

# 1. Apache, PHP, the Apache module, MySQL drivers, and the extension set
# that off-the-shelf PHP applications (forums, stores, CMSes) expect.
# Deliberately NOT installed: phar (deserialization vector), posix/pcntl
# (process control), ftp, sockets, soap. Add only if an app actually needs one.
# apk upgrade first: `apk add` only installs what is named, it never
# upgrades what the base image already ships (apk-tools, musl, busybox,
# openssl). Without this those stay pinned to the base image forever, so
# the daily update check would report the same upgrades on every run and
# rebuild endlessly, while the packages themselves never actually moved.
RUN apk upgrade --no-cache && apk add --no-cache \
    apache2 \
    php${PHP_VER} \
    php${PHP_VER}-apache2 \
    php${PHP_VER}-pdo \
    php${PHP_VER}-pdo_mysql \
    php${PHP_VER}-mysqli \
    php${PHP_VER}-session \
    php${PHP_VER}-mbstring \
    php${PHP_VER}-iconv \
    php${PHP_VER}-ctype \
    php${PHP_VER}-tokenizer \
    php${PHP_VER}-fileinfo \
    php${PHP_VER}-gd \
    php${PHP_VER}-exif \
    php${PHP_VER}-curl \
    php${PHP_VER}-dom \
    php${PHP_VER}-xml \
    php${PHP_VER}-simplexml \
    php${PHP_VER}-xmlreader \
    php${PHP_VER}-xmlwriter \
    php${PHP_VER}-intl \
    php${PHP_VER}-zip \
    php${PHP_VER}-bcmath \
    php${PHP_VER}-sodium \
    php${PHP_VER}-openssl \
    curl \
    tzdata

# 1a. OPcache, which is the one package that is not uniform across majors:
# 83 and 84 ship it separately, 85 compiles it into the core php85 package and
# publishes no php85-opcache at all. Naming it unconditionally above aborts a
# PHP_VER=85 build with "unable to select packages", so it is conditional here.
# Either way `php -m` reports "Zend OPcache" and the opcache.* ini keys in 4d
# apply - verify with: docker run --rm <img> php -m | grep -i opcache
RUN if apk add --no-cache --simulate php${PHP_VER}-opcache >/dev/null 2>&1; then \
        apk add --no-cache php${PHP_VER}-opcache; \
    else \
        php${PHP_VER} -m | grep -qi 'Zend OPcache' \
            || { echo "no opcache for php${PHP_VER}: no package and not built in"; exit 1; }; \
    fi

# 1b. Alpine 3.24 defaults to php85, so a non-default major installs only
# /usr/bin/phpXX. Provide the conventional name so tooling and any CLI
# scripts that call `php` keep working.
RUN ln -sf /usr/bin/php${PHP_VER} /usr/bin/php

# 2. Redirect Apache logs to stdout/stderr for Docker logging
RUN ln -sf /dev/stdout /var/log/apache2/access.log && \
    ln -sf /dev/stderr /var/log/apache2/error.log

# 3. Create the non-root www-data user at UID/GID 33.
# Alpine's own www-data is 82, but bind mounts carry raw numeric IDs and the
# Debian/Ubuntu hosts this runs on use 33 - so 82 would read as a foreign user
# and Apache would get EACCES on the mounted site. The stock group is dropped
# and recreated because it is fixed at GID 82.
RUN deluser www-data 2>/dev/null || true; \
    delgroup www-data 2>/dev/null || true; \
    addgroup -g 33 www-data && \
    adduser -u 33 -D -S -G www-data www-data

# 4. Configure Apache for running as non-root and secure header tokens.
# ServerRoot is moved off /var/www first: Alpine points it at /var/www, which
# holds the modules/logs/run symlinks, so bind-mounting a project over
# /var/www would mask them and Apache would fail to load a single module.
RUN sed -i 's|^ServerRoot /var/www|ServerRoot /etc/apache2|' /etc/apache2/httpd.conf && \
    ln -sf /usr/lib/apache2 /etc/apache2/modules && \
    ln -sf /var/log/apache2 /etc/apache2/logs && \
    ln -sf /run/apache2 /etc/apache2/run && \
    sed -i 's|/var/www/localhost/htdocs|/var/www/html|g' /etc/apache2/httpd.conf && \
    sed -i 's|LogFormat "%h |LogFormat "%a |g' /etc/apache2/httpd.conf && \
    sed -i 's|^\( *\)CustomLog \(.*\) combined$|\1CustomLog \2 combined env=!healthcheck|' \
        /etc/apache2/httpd.conf && \
    sed -i 's/User apache/User www-data/g' /etc/apache2/httpd.conf && \
    sed -i 's/Group apache/Group www-data/g' /etc/apache2/httpd.conf && \
    sed -i 's/^Listen .*/Listen 80/' /etc/apache2/httpd.conf && \
    echo "ServerTokens Prod" >> /etc/apache2/httpd.conf && \
    echo "ServerSignature Off" >> /etc/apache2/httpd.conf

# 4a. Drop modules and stock config we do not serve with.
# languages.conf must go with mod_negotiation: its LanguagePriority /
# ForceLanguagePriority directives are NOT <IfModule>-guarded and would
# abort startup once the module is gone.
RUN rm -f /etc/apache2/conf.d/info.conf \
          /etc/apache2/conf.d/userdir.conf \
          /etc/apache2/conf.d/languages.conf && \
    sed -i -E 's@^(LoadModule (autoindex|status|negotiation|userdir|info|cgid?)_module)@#\1@' \
        /etc/apache2/httpd.conf

# 4b. Enable mod_rewrite / .htaccess, point DocumentRoot at the mounted source,
# and apply response-header + exposure hardening.
# conf.d is included at the end of httpd.conf, so this overrides the defaults.
RUN printf '%s\n' \
    'ServerName ${APACHE_SERVER_NAME}' \
    '' \
    '# mod_rewrite, so RewriteEngine directives in .htaccess are understood' \
    'LoadModule rewrite_module modules/mod_rewrite.so' \
    '' \
    '# Behind Traefik: take the client IP from X-Forwarded-For so REMOTE_ADDR,' \
    '# access logs and any app-side rate limiting see the real visitor.' \
    'LoadModule remoteip_module modules/mod_remoteip.so' \
    '# CF-Connecting-IP, not X-Forwarded-For. Traefik only preserves an inbound' \
    '# X-Forwarded-For from peers in its forwardedHeaders.trustedIPs list, and' \
    '# Cloudflare is not in that list by default - so it discards the header' \
    '# Cloudflare sent and rewrites it to the Cloudflare edge address, which is' \
    '# why every visitor logged as a Cloudflare IP. CF-Connecting-IP carries the' \
    '# real client, is set by Cloudflare, and Traefik forwards it untouched.' \
    '# Alternative fix, if you prefer standard headers: add the Cloudflare ranges' \
    '# to forwardedHeaders.trustedIPs on the Traefik entrypoint and set this back' \
    '# to X-Forwarded-For.' \
    '# Header carrying the real client, switchable per deployment via the' \
    '# REMOTE_IP_HEADER env var (defaults to CF-Connecting-IP below). There is' \
    '# no way to make mod_remoteip try a second header: it accepts exactly one,' \
    '# and mod_headers cannot feed it because mod_remoteip always runs first in' \
    '# post_read_request regardless of module load order (both tested).' \
    'RemoteIPHeader ${REMOTE_IP_HEADER}' \
    '# Only these sources may assert an X-Forwarded-For. mod_remoteip walks the' \
    '# header right to left and stops at the first untrusted hop, so every hop' \
    '# in client -> Cloudflare -> Traefik -> Apache must be listed or the' \
    '# client IP resolves to Cloudflare instead of the real visitor. Trusting' \
    '# anything beyond these lets a client spoof its IP and evade bans.' \
    '' \
    '# Traefik, on the docker network' \
    'RemoteIPInternalProxy 10.0.0.0/8' \
    'RemoteIPInternalProxy 172.16.0.0/12' \
    'RemoteIPInternalProxy 192.168.0.0/16' \
    'RemoteIPInternalProxy 127.0.0.0/8' \
    '' \
    '# Cloudflare edge. Current as of the image build; refresh from' \
    '# https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6' \
    'RemoteIPInternalProxy 173.245.48.0/20' \
    'RemoteIPInternalProxy 103.21.244.0/22' \
    'RemoteIPInternalProxy 103.22.200.0/22' \
    'RemoteIPInternalProxy 103.31.4.0/22' \
    'RemoteIPInternalProxy 141.101.64.0/18' \
    'RemoteIPInternalProxy 108.162.192.0/18' \
    'RemoteIPInternalProxy 190.93.240.0/20' \
    'RemoteIPInternalProxy 188.114.96.0/20' \
    'RemoteIPInternalProxy 197.234.240.0/22' \
    'RemoteIPInternalProxy 198.41.128.0/17' \
    'RemoteIPInternalProxy 162.158.0.0/15' \
    'RemoteIPInternalProxy 104.16.0.0/13' \
    'RemoteIPInternalProxy 104.24.0.0/14' \
    'RemoteIPInternalProxy 172.64.0.0/13' \
    'RemoteIPInternalProxy 131.0.72.0/22' \
    'RemoteIPInternalProxy 2400:cb00::/32' \
    'RemoteIPInternalProxy 2606:4700::/32' \
    'RemoteIPInternalProxy 2803:f800::/32' \
    'RemoteIPInternalProxy 2405:b500::/32' \
    'RemoteIPInternalProxy 2405:8100::/32' \
    'RemoteIPInternalProxy 2a06:98c0::/29' \
    'RemoteIPInternalProxy 2c0f:f248::/32' \
    '' \
    '# Traefik terminates TLS, so tell PHP the original scheme was https.' \
    '# Without this apps build http:// URLs and redirect loop behind the proxy.' \
    '<IfModule setenvif_module>' \
    '    SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on' \
    '' \
    '    # Keep the 30s container healthcheck out of the access log. Both must' \
    '    # hold: the loopback origin AND the user-agent, so neither alone can' \
    '    # hide a request. CONN_REMOTE_ADDR is the raw peer address - unlike' \
    '    # REMOTE_ADDR it is NOT rewritten by mod_remoteip, so a forged' \
    '    # X-Forwarded-For cannot make an outside request look like loopback.' \
    '    # Errors it triggers still reach the error log.' \
    '    SetEnvIfExpr "%{CONN_REMOTE_ADDR} -eq '"'"'127.0.0.1'"'"' && %{HTTP_USER_AGENT} == '"'"'docker-healthcheck'"'"'" healthcheck' \
    '</IfModule>' \
    '' \
    '# No TRACE (cross-site tracing) and no inode/size ETags (info leak)' \
    'TraceEnable Off' \
    'FileETag None' \
    '' \
    '# Cap request body size at 33M, just above PHP post_max_size (32M)' \
    'LimitRequestBody ${APACHE_LIMIT_REQUEST_BODY}' \
    '' \
    '# The stock DocumentRoot is /var/www/localhost/htdocs, but the application' \
    '# source is mounted at /var/www/html (see docker-compose.yml).' \
    'DocumentRoot "/var/www/html"' \
    '' \
    '<Directory "/var/www/html">' \
    '    # FollowSymLinks is required for RewriteRule to work inside .htaccess.' \
    '    # Indexes is deliberately omitted: no directory listings.' \
    '    Options FollowSymLinks' \
    '' \
    '    # Let .htaccess files take effect (rewrites, auth, headers, ...)' \
    '    AllowOverride All' \
    '' \
    '    Require all granted' \
    '</Directory>' \
    '' \
    '# Dotfiles and dot-directories (.git, .env, .svn), but not /.well-known/*' \
    '<FilesMatch "^\.">' \
    '    Require all denied' \
    '</FilesMatch>' \
    '<DirectoryMatch "/\.(?!well-known)">' \
    '    Require all denied' \
    '</DirectoryMatch>' \
    '' \
    '# Files that ship with a repo but must never be served' \
    '<FilesMatch "(?i)(^(composer|package)(-lock)?\.(json|lock)$|\.(env|ini|log|sh|sql|bak|swp|dist|tpl)$)">' \
    '    Require all denied' \
    '</FilesMatch>' \
    '' \
    '<IfModule headers_module>' \
    '    Header always set X-Content-Type-Options "nosniff"' \
    '    Header always set X-Frame-Options "DENY"' \
    '    Header always set Referrer-Policy "no-referrer"' \
    '    Header always set Permissions-Policy "geolocation=(), camera=(), microphone=()"' \
    '    # No CSP by default: a store needs its payment provider'"'"'s scripts and' \
    '    # frames, and a wrong policy breaks checkout silently. Set a policy per' \
    '    # site in its .htaccess, e.g. for a Stripe checkout:' \
    '    #   Header always set Content-Security-Policy "default-src '"'"'self'"'"'; \' \
    '    #     script-src '"'"'self'"'"' https://js.stripe.com; frame-src https://js.stripe.com"' \
    '    # Belt and braces alongside expose_php=Off' \
    '    Header always unset X-Powered-By' \
    '    # Add HSTS only once this is served over TLS:' \
    '    # Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"' \
    '</IfModule>' \
    > /etc/apache2/conf.d/custom.conf

# 4c. Size the MPM to the container, not to a bare metal host.
# Alpine ships prefork with MaxRequestWorkers 250 (conf.d/mpm.conf), which is
# wrong here in two directions: the compose files cap the container at 256 pids,
# so 250 children plus the parent plus the healthcheck curl runs the process
# table out and Apache starts failing to fork instead of queueing; and with
# mod_php every child carries the interpreter, so 250 of them against a 2048M
# memory limit is an OOM kill long before the worker count is reached.
# 24 is the ceiling the memory limit actually affords: a mod_php child serving
# a forum or store page sits around 60-90M resident, so ~2G is the wall. Excess
# connections wait in the listen backlog, which degrades far better than either
# failure mode above. Raise this only alongside the compose memory limit.
# All five are env vars (defaults below) so a deployment with a different
# memory limit can resize without a rebuild - but they are one budget: keep
# MaxRequestWorkers x per-child RSS under the container memory limit, and
# MaxSpareServers at or above MinSpareServers, or prefork silently raises it
# to MinSpareServers + 1 - no warning, so a bad pair just does not take effect.
# Named zz- so it sorts after mpm.conf in conf.d and therefore wins; custom.conf
# would not, it sorts before it.
RUN printf '%s\n' \
    '<IfModule mpm_prefork_module>' \
    '    StartServers            ${APACHE_START_SERVERS}' \
    '    MinSpareServers         ${APACHE_MIN_SPARE_SERVERS}' \
    '    MaxSpareServers         ${APACHE_MAX_SPARE_SERVERS}' \
    '    # ServerLimit is the hard ceiling on MaxRequestWorkers - prefork' \
    '    # defaults it to 256 and silently clamps anything above - so it' \
    '    # tracks the same variable, otherwise raising the env var past 256' \
    '    # would log a warning and have no effect.' \
    '    ServerLimit             ${APACHE_MAX_REQUEST_WORKERS}' \
    '    MaxRequestWorkers       ${APACHE_MAX_REQUEST_WORKERS}' \
    '    # Recycle children periodically so a slow leak in the app or an' \
    '    # extension cannot accumulate for the life of the container.' \
    '    MaxConnectionsPerChild  ${APACHE_MAX_CONNECTIONS_PER_CHILD}' \
    '</IfModule>' \
    > /etc/apache2/conf.d/zz-mpm.conf

# 4d. PHP hardening. The risky functions live in the core "standard" extension,
# which cannot be uninstalled, so they are disabled at the interpreter instead.
RUN printf '%s\n' \
    '; Do not advertise PHP (removes the X-Powered-By header)' \
    'expose_php = Off' \
    '' \
    '; Log errors, never render them to the client' \
    'display_errors = ${PHP_DISPLAY_ERRORS}' \
    'display_startup_errors = Off' \
    'log_errors = On' \
    '; Keep argument values out of stack traces (they leak credentials)' \
    'zend.exception_ignore_args = On' \
    '' \
    '; No remote code through the filesystem API. allow_url_include stays Off' \
    '; unconditionally - it turns any tainted include path into remote code' \
    '; execution and no application legitimately needs it.' \
    'allow_url_include = Off' \
    '' \
    '; Values MUST be 0 or 1, never Off/On. With ${} substitution PHP stores the' \
    '; literal string, so ini_get() returns "Off" - which is TRUTHY in PHP - and' \
    '; any app testing if(ini_get("allow_url_fopen")) takes the wrong branch.' \
    '; IPS steam auth does exactly that to decide whether to fall back to cURL.' \
    '; allow_url_fopen is per-deployment: the store requires it, the landing' \
    '; page and forums do not. Disabled by default; a compose file opts in.' \
    '; Enabling it permits SSRF through file_get_contents on a tainted URL,' \
    '; but not code execution, which allow_url_include above still blocks.' \
    'allow_url_fopen = ${PHP_ALLOW_URL_FOPEN}' \
    '' \
    '; Follow the TZ environment variable set by the deployment' \
    'date.timezone = ${TZ}' \
    '' \
    '; Confine filesystem access to the app and its temp dir. This is /var/www,' \
    '; not the docroot, so code kept beside html/ (vendor, config, ..) still' \
    '; loads while the rest of the filesystem stays off limits.' \
    'open_basedir = ${PHP_OPEN_BASEDIR}' \
    '' \
    '; Command execution, dynamic extension loading and source disclosure.' \
    '; putenv/symlink/link/php_uname are deliberately left ENABLED: the forum' \
    '; and store source references all of them, and blocking them causes fatals' \
    '; rather than protection (php_uname only discloses the OS string).' \
    '; The exec family is what actually matters here and stays disabled.' \
    'disable_functions = ${PHP_DISABLE_FUNCTIONS}' \
    '' \
    '; Session cookie hardening. INERT until the session extension is present:' \
    '; Alpine ships it separately, so add php${PHP_VER}-session above if the app uses' \
    '; sessions (without it session_start() is an undefined function).' \
    'session.use_strict_mode = 1' \
    'session.use_only_cookies = 1' \
    'session.cookie_httponly = 1' \
    'session.cookie_samesite = "Lax"' \
    '; Enable once served over TLS:' \
    '; session.cookie_secure = 1' \
    '' \
    '; Resource ceilings. Sized for forum attachments and product images;' \
    '; must stay under the LimitRequestBody set in custom.conf.' \
    'memory_limit = ${PHP_MEMORY_LIMIT}' \
    'max_execution_time = ${PHP_MAX_EXECUTION_TIME}' \
    'post_max_size = ${PHP_POST_MAX_SIZE}' \
    'upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}' \
    'max_file_uploads = ${PHP_MAX_FILE_UPLOADS}' \
    '; Form fields accepted per request. The 1000 default is exceeded by large' \
    '; admin forms - IPS permission matrices, store settings pages - and PHP' \
    '; drops the overflow SILENTLY: no error, no warning, the fields simply' \
    '; never arrive and the save looks like it worked.' \
    'max_input_vars = 5000' \
    '' \
    '; Opcache. validate_timestamps stays on so a deploy takes effect without' \
    '; restarting the container; set it to 0 only for immutable image deploys.' \
    'opcache.enable = ${PHP_OPCACHE_ENABLE}' \
    'opcache.memory_consumption = ${PHP_OPCACHE_MEMORY}' \
    'opcache.max_accelerated_files = 20000' \
    'opcache.validate_timestamps = ${PHP_OPCACHE_VALIDATE_TIMESTAMPS}' \
    'opcache.revalidate_freq = ${PHP_OPCACHE_REVALIDATE_FREQ}' \
    > /etc/php${PHP_VER}/conf.d/99_hardening.ini

# 5. Fix permissions for Apache runtime files so a non-root user can write to them
RUN mkdir -p /var/www/html /run/apache2 && \
    chown -R www-data:www-data /var/www/html /run/apache2 /var/log/apache2

# Defaults. TZ keeps date.timezone from being empty (PHP warns at startup if
# it is); PHP_ALLOW_URL_FOPEN stays Off unless a compose file opts in.
ENV TZ=UTC \
    REMOTE_IP_HEADER=CF-Connecting-IP \
    APACHE_SERVER_NAME=localhost \
    APACHE_LIMIT_REQUEST_BODY=34603008 \
    APACHE_START_SERVERS=3 \
    APACHE_MIN_SPARE_SERVERS=3 \
    APACHE_MAX_SPARE_SERVERS=8 \
    APACHE_MAX_REQUEST_WORKERS=24 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=500 \
    PHP_ALLOW_URL_FOPEN=0 \
    PHP_DISPLAY_ERRORS=0 \
    PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXECUTION_TIME=60 \
    PHP_POST_MAX_SIZE=32M \
    PHP_UPLOAD_MAX_FILESIZE=24M \
    PHP_MAX_FILE_UPLOADS=20 \
    PHP_OPEN_BASEDIR=/var/www:/tmp \
    PHP_DISABLE_FUNCTIONS=exec,passthru,shell_exec,system,proc_open,proc_close,proc_get_status,proc_nice,proc_terminate,popen,pcntl_exec,pcntl_fork,dl,show_source,highlight_file \
    PHP_OPCACHE_ENABLE=1 \
    PHP_OPCACHE_MEMORY=128 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=2

WORKDIR /var/www/html

# Port 80, so Traefik can route to it without a per-service port override.
# Running as a non-root user still binds it because the compose files set
# net.ipv4.ip_unprivileged_port_start=0.
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fsS -A docker-healthcheck http://127.0.0.1/ -o /dev/null || exit 1

# Run Apache in the foreground
CMD ["httpd", "-D", "FOREGROUND"]
