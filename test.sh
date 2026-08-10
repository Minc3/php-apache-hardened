#!/bin/bash
#
# Behavioural test suite for php-apache-hardened, both variants.
#
# build-all.sh already smoke-tests every image it publishes: can it serve a
# bind-mounted site, read-only, as UID 33. This asks the other question - does
# every environment variable the README documents actually DO what it says?
# A variable that is declared but not wired reads exactly like one that works,
# right up until someone relies on it in production.
#
# Two passes over every variant and PHP major:
#
#   defaults   no -e flags at all, asserting the hardened values the README
#              promises to anyone who runs the image with no configuration
#   custom     every documented variable overridden, asserting each one took
#              effect - not merely that the container still started
#
# Plus, for the -fpm images, the things that only exist there: the FastCGI path
# guard, the request-body limit mod_proxy_fcgi does not enforce on its own, and
# the supervisor that has to take the container down when either process dies.
#
#   ./test.sh                     everything: both variants, every major
#   ./test.sh --php 8.3           one major
#   ./test.sh --variant fpm       one variant (fpm | modphp)
#   ./test.sh --no-build          reuse images already built locally
#   ./test.sh --image REF         test one specific image (needs --variant)
#   ./test.sh --keep              leave containers behind for inspection
#   ./test.sh --quiet             only report failures and the summary
#
# Exit status is 0 when everything passes and 1 otherwise, so this is usable
# from CI or as a gate before publishing:
#
#   ./test.sh && ./build-all.sh
#
# A full run builds six images and starts around forty short-lived containers;
# budget ten minutes cold, rather less with a warm build cache.
#
# The docroot is baked into a throwaway image rather than bind-mounted, which
# keeps the suite runnable anywhere Docker is - including Docker Desktop, where
# the container-side path of a -v argument gets rewritten before the daemon
# sees it. The bind-mounted read-only case is what build-all.sh's smoke test
# covers. Every container here still runs exactly as the README documents it
# otherwise: non-root, read-only root filesystem, tmpfs for the writable paths.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP=0; QUIET=0; NO_BUILD=0; ONLY_PHP=""; ONLY_VARIANT=""; ONE_IMAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --php)      ONLY_PHP="${2:-}"; shift 2 ;;
        --variant)  ONLY_VARIANT="${2:-}"; shift 2 ;;
        --image)    ONE_IMAGE="${2:-}"; shift 2 ;;
        --no-build) NO_BUILD=1; shift ;;
        --keep)     KEEP=1; shift ;;
        --quiet|-q) QUIET=1; shift ;;
        -h|--help)  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }

# ---------------------------------------------------------------- variants ---
variant_dockerfile() { case "$1" in fpm) echo "Dockerfile.fpm" ;; *) echo "Dockerfile" ;; esac; }
variant_probe()      { case "$1" in fpm) echo "php*-fpm"       ;; *) echo "php*-apache2" ;; esac; }
variant_sapi()       { case "$1" in fpm) echo "fpm-fcgi"       ;; *) echo "apache2handler" ;; esac; }

if [[ -n "$ONLY_VARIANT" ]]; then
    case "$ONLY_VARIANT" in
        fpm|modphp)     VARIANTS="$ONLY_VARIANT" ;;
        mod_php|apache) VARIANTS="modphp" ;;
        *) echo "unknown variant: $ONLY_VARIANT (expected fpm or modphp)" >&2; exit 2 ;;
    esac
else
    VARIANTS="modphp fpm"
fi

if [[ -n "$ONE_IMAGE" && -z "$ONLY_VARIANT" ]]; then
    echo "--image needs --variant, so the suite knows which SAPI to expect" >&2
    exit 2
fi

# ---------------------------------------------------------------- plumbing ---
PASS=0; FAIL=0; FAILURES=""
CTX="setup"
STAMP="$$"
IMAGE_UNDER_TEST=""

say()   { (( QUIET )) || printf '%s\n' "$*"; }
head1() { (( QUIET )) || printf '\n=== %s\n' "$*"; }
head2() { (( QUIET )) || printf '  -- %s\n' "$*"; }

ok()  { PASS=$((PASS+1)); }
bad() {
    FAIL=$((FAIL+1))
    FAILURES="${FAILURES}"$'\n'"    [${CTX}] $1 -- got [$2] want [$3]"
    printf '     FAIL %-34s got=[%s] want=[%s]\n' "$1" "$2" "$3"
}
chk()        { if [[ "$2" == "$3" ]]; then ok; else bad "$1" "$2" "$3"; fi; }
chk_has()    { case "$2" in *"$3"*) ok ;; *) bad "$1" "$2" "*$3*" ;; esac; }
chk_truthy() { case "$2" in 1|On|on|true|TRUE) ok ;; *) bad "$1" "$2" "truthy" ;; esac; }
chk_falsey() { case "$2" in ""|0|Off|off|false) ok ;; *) bad "$1" "$2" "falsey" ;; esac; }
chk_ge()     { if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= $3 )); then ok; else bad "$1" "$2" ">=$3"; fi; }

# Inspecting a container must never abort the run: a dead one is a failure to
# report, not a reason to stop testing everything else.
try() { "$@" 2>/dev/null || true; }

# The same, but keeping stderr. httpd -t, php-fpm -t and the whole Apache error
# log report there, so try() would hand the assertion an empty string and it
# would then pass or fail on nothing at all.
try_all() { "$@" 2>&1 || true; }

CONTAINERS=""
cleanup() {
    if (( KEEP )); then say "--keep: leaving${CONTAINERS}"; return; fi
    if [[ -n "$CONTAINERS" ]]; then
        # shellcheck disable=SC2086
        docker rm -f $CONTAINERS >/dev/null 2>&1 || true
    fi
    rm -rf "${DIR}/.probe.${STAMP}" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------ probe ----
# A page that dumps the settings under test, so an assertion checks what PHP
# actually resolved rather than what the container was asked for.
#
# The context directory is created relative to the repo rather than as an
# absolute path: mkdir -p on a UNC working directory fails under Git Bash, and
# this suite should run wherever the images are being worked on.
build_probe_context() {
    local ctx=".probe.${STAMP}"
    rm -rf "$ctx"; mkdir -p "$ctx/html/sub"
    cat > "$ctx/html/index.php" <<'PHP'
<?php
$keys = ['memory_limit','max_execution_time','post_max_size','upload_max_filesize',
         'max_file_uploads','open_basedir','disable_functions','allow_url_fopen',
         'allow_url_include','display_errors','date.timezone','expose_php',
         'max_input_vars','opcache.enable','opcache.memory_consumption',
         'opcache.validate_timestamps','opcache.revalidate_freq',
         'session.cookie_httponly','session.cookie_samesite','cgi.fix_pathinfo'];
foreach ($keys as $k) { echo $k, '=', (string) ini_get($k), "\n"; }
echo 'sapi=', php_sapi_name(), "\n";
echo 'version=', PHP_VERSION, "\n";
echo 'tz_env=', (getenv('TZ') === false ? 'FALSE' : getenv('TZ')), "\n";
echo 'remote_addr=', $_SERVER['REMOTE_ADDR'] ?? 'unset', "\n";
echo 'https=', $_SERVER['HTTPS'] ?? 'unset', "\n";
echo 'exec_exists=', var_export(function_exists('exec'), true), "\n";
echo 'passthru_exists=', var_export(function_exists('passthru'), true), "\n";
echo 'opcache_loaded=', var_export(extension_loaded('Zend OPcache'), true), "\n";
$need = ['pdo_mysql','mysqli','session','mbstring','gd','curl','dom','zip','intl','bcmath'];
echo 'missing_ext=', implode(',', array_filter($need, fn($e) => !extension_loaded($e))), "\n";
PHP
    # Files the deny rules must refuse, and one that must still be served.
    printf 'must-not-be-served\n' > "$ctx/html/.env"
    printf 'plain\n'              > "$ctx/html/static.txt"
    printf '<?php echo "SUB";'    > "$ctx/html/sub/index.php"
    printf 'FROM BASE_IMAGE\nCOPY --chown=33:33 html /var/www/html\n' > "$ctx/Dockerfile.in"
    printf '%s' "$ctx"
}

# Bake the probe docroot onto an image under test. Building from inside the
# context directory keeps the argument a bare "." - an absolute path here would
# be rewritten on Docker Desktop before the daemon ever saw it.
probe_image() {
    local base="$1" ctx="$2"
    local tag
    tag="probe-${STAMP}:$(printf '%s' "$base" | tr '/:' '__')"
    sed "s|BASE_IMAGE|${base}|" "$ctx/Dockerfile.in" > "$ctx/Dockerfile"
    ( cd "$ctx" && docker build -q -t "$tag" . >/dev/null 2>&1 ) || return 1
    printf '%s' "$tag"
}

# ------------------------------------------------------------------- runs ----
start() { # start <name> <image> <variant> [env args...]
    local name="$1" image="$2" variant="$3"; shift 3
    local extra=()
    if [[ "$variant" == fpm ]]; then
        extra=(--tmpfs "/run/php-fpm:uid=33,gid=33,mode=0755,noexec,nosuid,nodev")
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    CONTAINERS="${CONTAINERS} ${name}"
    docker run -d --name "$name" \
        --user 33:33 --read-only \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --tmpfs "/run/apache2:uid=33,gid=33,mode=0755,noexec,nosuid,nodev" \
        --tmpfs "/tmp:uid=33,gid=33,mode=1777,noexec,nosuid,nodev" \
        "${extra[@]}" "$@" "$image" >/dev/null 2>&1
}

# The probe page, once the container answers. Empty means it never came up.
probe() {
    local i body
    for i in $(seq 1 25); do
        body="$(try docker exec "$1" curl -sf http://127.0.0.1/)"
        case "$body" in *sapi=*) printf '%s' "$body"; return 0 ;; esac
        sleep 1
    done
    printf ''
}

val()  { printf '%s\n' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }
code() { try docker exec "$1" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1$2"; }

# HEALTHCHECK has a start period, so sampling immediately reports "starting"
# whatever the container is doing. Wait for it to resolve either way.
health() {
    local i s=""
    for i in $(seq 1 45); do
        s="$(try docker inspect "$1" --format '{{.State.Health.Status}}')"
        [[ "$s" != starting ]] && { printf '%s' "$s"; return; }
        sleep 1
    done
    printf '%s' "$s"
}

# ------------------------------------------------------- shared assertions ---
assert_serving() { # <name> <body> <variant>
    local name="$1" body="$2" variant="$3" hdrs
    chk "sapi"            "$(val "$body" sapi)"           "$(variant_sapi "$variant")"
    chk "opcache loaded"  "$(val "$body" opcache_loaded)" "true"
    chk "no missing ext"  "$(val "$body" missing_ext)"    ""
    chk "health"          "$(health "$name")"             "healthy"
    chk "dotfile denied"  "$(code "$name" /.env)"         "403"
    chk "static served"   "$(code "$name" /static.txt)"   "200"
    chk "DirectoryIndex"  "$(code "$name" /sub/)"         "200"
    chk "missing .php"    "$(code "$name" /nope.php)"     "404"
    # The real attack shape - /uploads/avatar.jpg/shell.php - must not execute
    # on either variant. Note this is NOT the same question as
    # /index.php/anything, which mod_php legitimately serves with PATH_INFO.
    chk ".php suffix on static file" "$(code "$name" /static.txt/x.php)" "404"
    chk "no apache warns" "$(try_all docker logs "$name" | grep -ci 'AH0[0-9]*: WARNING')" "0"

    # Response headers are fixed policy and must survive any configuration.
    hdrs="$(try docker exec "$name" curl -sI http://127.0.0.1/)"
    chk_has "X-Content-Type-Options" "$hdrs" "nosniff"
    chk_has "X-Frame-Options"        "$hdrs" "DENY"
    chk_has "Referrer-Policy"        "$hdrs" "no-referrer"
    case "$hdrs" in
        *[Xx]-[Pp]owered-[Bb]y*) bad "X-Powered-By removed" "present" "absent" ;;
        *) ok ;;
    esac

    if [[ "$variant" == fpm ]]; then
        # The FastCGI path guard: neither of these may reach the interpreter.
        chk "orphan path-info" "$(code "$name" /index.php/nonexistent.php)" "404"
        chk "fpm-ping" \
            "$(try docker exec "$name" curl -sf -A docker-healthcheck http://127.0.0.1/fpm-ping)" "pong"
        chk_falsey "cgi.fix_pathinfo" "$(val "$body" cgi.fix_pathinfo)"
    fi
}

assert_defaults() { # <name> <body>
    local body="$2"
    chk "memory_limit"            "$(val "$body" memory_limit)"                "256M"
    chk "max_execution_time"      "$(val "$body" max_execution_time)"          "60"
    chk "post_max_size"           "$(val "$body" post_max_size)"               "32M"
    chk "upload_max_filesize"     "$(val "$body" upload_max_filesize)"         "24M"
    chk "max_file_uploads"        "$(val "$body" max_file_uploads)"            "20"
    chk "open_basedir"            "$(val "$body" open_basedir)"                "/var/www:/tmp"
    chk "date.timezone"           "$(val "$body" date.timezone)"               "UTC"
    chk "TZ in environment"       "$(val "$body" tz_env)"                      "UTC"
    chk "max_input_vars"          "$(val "$body" max_input_vars)"              "5000"
    chk "opcache.memory"          "$(val "$body" opcache.memory_consumption)"  "128"
    chk "opcache.revalidate_freq" "$(val "$body" opcache.revalidate_freq)"     "2"
    chk_truthy "opcache.enable"              "$(val "$body" opcache.enable)"
    chk_truthy "opcache.validate_timestamps" "$(val "$body" opcache.validate_timestamps)"
    chk_truthy "session.cookie_httponly"     "$(val "$body" session.cookie_httponly)"
    chk_falsey "allow_url_fopen"             "$(val "$body" allow_url_fopen)"
    chk_falsey "allow_url_include"           "$(val "$body" allow_url_include)"
    chk_falsey "display_errors"              "$(val "$body" display_errors)"
    chk_falsey "expose_php"                  "$(val "$body" expose_php)"
    chk_has "disable_functions" "$(val "$body" disable_functions)" "shell_exec"
    chk "exec disabled"     "$(val "$body" exec_exists)"     "false"
    chk "passthru disabled" "$(val "$body" passthru_exists)" "false"
}

# Every documented variable, set to something that is not the default, so a
# value that merely happens to match cannot pass by accident.
COMMON_ENV=(
    -e TZ=Asia/Tokyo
    -e APACHE_SERVER_NAME=example.test
    -e APACHE_LIMIT_REQUEST_BODY=1000
    -e REMOTE_IP_HEADER=X-Forwarded-For
    -e PHP_ALLOW_URL_FOPEN=1
    -e PHP_DISPLAY_ERRORS=1
    -e PHP_OPEN_BASEDIR=/var/www:/tmp:/usr/share
    -e PHP_DISABLE_FUNCTIONS=exec,system
    -e PHP_MEMORY_LIMIT=333M
    -e PHP_MAX_EXECUTION_TIME=45
    -e PHP_POST_MAX_SIZE=11M
    -e PHP_UPLOAD_MAX_FILESIZE=9M
    -e PHP_MAX_FILE_UPLOADS=7
    -e PHP_OPCACHE_ENABLE=1
    -e PHP_OPCACHE_MEMORY=77
    -e PHP_OPCACHE_VALIDATE_TIMESTAMPS=0
    -e PHP_OPCACHE_REVALIDATE_FREQ=9
)
MODPHP_ENV=(
    -e APACHE_START_SERVERS=6
    -e APACHE_MIN_SPARE_SERVERS=6
    -e APACHE_MAX_SPARE_SERVERS=9
    -e APACHE_MAX_REQUEST_WORKERS=40
    -e APACHE_MAX_CONNECTIONS_PER_CHILD=100
)
# pm.start_servers and the two spare-server bounds are ignored by PHP-FPM
# unless pm is dynamic, and the custom pass above deliberately uses static so
# the worker count can be asserted exactly. They would go untested otherwise,
# so they get their own short run.
FPM_DYNAMIC_ENV=(
    -e PHP_FPM_PM=dynamic
    -e PHP_FPM_START_SERVERS=4
    -e PHP_FPM_MIN_SPARE_SERVERS=2
    -e PHP_FPM_MAX_SPARE_SERVERS=6
)
FPM_ENV=(
    -e APACHE_START_SERVERS=1
    -e APACHE_THREADS_PER_CHILD=32
    -e APACHE_MAX_REQUEST_WORKERS=100
    -e APACHE_MIN_SPARE_THREADS=8
    -e APACHE_MAX_SPARE_THREADS=40
    -e APACHE_MAX_CONNECTIONS_PER_CHILD=1000
    -e APACHE_PROXY_TIMEOUT=60
    -e PHP_FPM_PM=static
    -e PHP_FPM_MAX_CHILDREN=7
    -e PHP_FPM_MAX_REQUESTS=99
    -e PHP_FPM_REQUEST_TERMINATE_TIMEOUT=50
    -e PHP_FPM_SLOWLOG_TIMEOUT=3s
)

assert_custom() { # <name> <body> <variant>
    local name="$1" body="$2" variant="$3" ip hpid envs
    chk "memory_limit"        "$(val "$body" memory_limit)"               "333M"
    chk "max_execution_time"  "$(val "$body" max_execution_time)"         "45"
    chk "post_max_size"       "$(val "$body" post_max_size)"              "11M"
    chk "upload_max_filesize" "$(val "$body" upload_max_filesize)"        "9M"
    chk "max_file_uploads"    "$(val "$body" max_file_uploads)"           "7"
    chk "open_basedir"        "$(val "$body" open_basedir)"               "/var/www:/tmp:/usr/share"
    chk "date.timezone"       "$(val "$body" date.timezone)"              "Asia/Tokyo"
    chk "TZ in environment"   "$(val "$body" tz_env)"                     "Asia/Tokyo"
    chk "opcache.memory"      "$(val "$body" opcache.memory_consumption)" "77"
    chk "opcache.reval_freq"  "$(val "$body" opcache.revalidate_freq)"    "9"
    chk_falsey "opcache.validate_timestamps" "$(val "$body" opcache.validate_timestamps)"
    chk_truthy "allow_url_fopen" "$(val "$body" allow_url_fopen)"
    chk_truthy "display_errors"  "$(val "$body" display_errors)"

    # These are fixed policy: no environment setting may relax them.
    chk_falsey "allow_url_include stays off" "$(val "$body" allow_url_include)"
    chk_falsey "expose_php stays off"        "$(val "$body" expose_php)"

    # A narrowed disable_functions must genuinely re-enable what it dropped,
    # otherwise the variable is decorative.
    chk "disable_functions"   "$(val "$body" disable_functions)" "exec,system"
    chk "exec still disabled" "$(val "$body" exec_exists)"       "false"
    chk "passthru re-enabled" "$(val "$body" passthru_exists)"   "true"

    # ServerName is only used for self-referential URLs and UseCanonicalName is
    # Off, so force the fallback with an HTTP/1.0 request carrying no Host.
    chk_has "APACHE_SERVER_NAME" \
        "$(try docker exec "$name" curl -s -0 -o /dev/null -D - -H 'Host:' http://127.0.0.1/sub | grep -i '^location:')" \
        "example.test"

    # A body over the cap must be refused before the application sees it. On
    # -fpm this is the check mod_proxy_fcgi does not perform by itself.
    try docker exec "$name" sh -c 'head -c 2000 /dev/zero | tr "\0" "a" > /tmp/big; head -c 200 /dev/zero | tr "\0" "a" > /tmp/small'
    chk "over LimitRequestBody -> 413" \
        "$(try docker exec "$name" curl -s -o /dev/null -w '%{http_code}' --data-binary @/tmp/big http://127.0.0.1/index.php)" "413"
    chk "under LimitRequestBody -> 200" \
        "$(try docker exec "$name" curl -s -o /dev/null -w '%{http_code}' --data-binary @/tmp/small http://127.0.0.1/index.php)" "200"

    # mod_remoteip must honour the header it was pointed at. Asserted from a
    # second container, which sits inside the trusted 172.16/12 proxy range.
    ip="$(try docker inspect "$name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
    if [[ -z "$ip" ]]; then
        bad "container has an IP" "" "an address"
    else
        chk "REMOTE_IP_HEADER honoured" \
            "$(try docker run --rm --entrypoint curl "$IMAGE_UNDER_TEST" -s -H 'X-Forwarded-For: 203.0.113.9' "http://${ip}/" | grep '^remote_addr=' | cut -d= -f2)" \
            "203.0.113.9"
        if [[ "$variant" == fpm ]]; then
            # The pool ping must not be reachable from off-box - including by a
            # client asserting loopback through the trusted proxy header, which
            # is why that rule tests CONN_REMOTE_ADDR and not REMOTE_ADDR.
            chk "fpm-ping refused off-box" \
                "$(try docker run --rm --entrypoint curl "$IMAGE_UNDER_TEST" -s -o /dev/null -w '%{http_code}' "http://${ip}/fpm-ping")" "403"
            chk "fpm-ping refused when spoofed" \
                "$(try docker run --rm --entrypoint curl "$IMAGE_UNDER_TEST" -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 127.0.0.1' "http://${ip}/fpm-ping")" "403"
        fi
    fi

    if [[ "$variant" == fpm ]]; then
        # pm=static means exactly max_children workers, no more and no fewer.
        chk "pm=static -> 7 workers" \
            "$(try docker exec "$name" sh -c 'ps -o args | grep -c "^php-fpm: pool www"')" "7"
        # 100 workers over 32 threads is 4 children, and the worker count is
        # rounded up to fill them - the arithmetic the entrypoint exists for.
        hpid="$(try docker exec "$name" sh -c "pgrep -f 'httpd -D FOREGROUND' | head -1")"
        envs="$(try docker exec "$name" sh -c "tr '\\0' '\\n' < /proc/${hpid}/environ")"
        chk "derived APACHE_SERVER_LIMIT"  "$(printf '%s' "$envs" | grep '^APACHE_SERVER_LIMIT=' | cut -d= -f2)" "4"
        chk "MaxRequestWorkers rounded up" "$(printf '%s' "$envs" | grep '^APACHE_MAX_REQUEST_WORKERS=' | cut -d= -f2)" "128"
        # And the pool actually resolved the ${} references it was given.
        chk "fpm pool values resolved" \
            "$(try_all docker exec "$name" php-fpm -tt | grep -cE 'pm = static|pm.max_children = 7|pm.max_requests = 99|request_terminate_timeout = 50|request_slowlog_timeout = 3s')" "5"
    else
        # StartServers=6 plus the parent. Prefork may add more to satisfy
        # MinSpareServers, so this is a floor rather than an exact count.
        chk_ge "StartServers honoured" "$(try docker exec "$name" sh -c 'ps -o args | grep -c "^httpd"')" "7"
    fi
}

# Dropping the /run/php-fpm tmpfs is the one way the FPM variant gets
# misconfigured in practice, because it is the only thing that differs from a
# working mod_php compose file. FPM's own error ("Read-only file system (30)")
# names the symptom and not the fix, so the entrypoint checks first and prints
# the line to add. Assert the advice, not just the failure - an unhelpful
# message here costs somebody an afternoon.
assert_missing_tmpfs() { # <image> <major>
    local image="$1" major="$2" name="notmpfs-${2}-${STAMP}" out rc
    docker rm -f "$name" >/dev/null 2>&1 || true
    CONTAINERS="${CONTAINERS} ${name}"
    # Deliberately without --tmpfs /run/php-fpm, everything else as documented.
    out="$(docker run --name "$name" --user 33:33 --read-only \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --tmpfs "/run/apache2:uid=33,gid=33,mode=0755,noexec,nosuid,nodev" \
        --tmpfs "/tmp:uid=33,gid=33,mode=1777,noexec,nosuid,nodev" \
        "$image" 2>&1)" && rc=0 || rc=$?
    chk "missing tmpfs fails fast" "$([[ "${rc:-0}" != 0 ]] && echo nonzero || echo zero)" "nonzero"
    chk_has "names the directory"  "$out" "/run/php-fpm is not writable"
    chk_has "prints the fix"       "$out" "uid=33,gid=33,mode=0755"
    # It must not degrade into FPM's own unhelpful error instead.
    case "$out" in
        *"Read-only file system (30)"*) bad "advice replaces FPM's error" "FPM error shown" "entrypoint advice" ;;
        *) ok ;;
    esac
    docker rm -f "$name" >/dev/null 2>&1 || true
}

assert_fpm_dynamic() { # <image> <variant> <major>
    local image="$1" variant="$2" major="$3" name resolved
    name="dyn-${major}-${STAMP}"
    start "$name" "$image" "$variant" "${FPM_DYNAMIC_ENV[@]}"
    if [[ -z "$(probe "$name")" ]]; then
        bad "pm=dynamic: came up" "no response" "the probe page"; return
    fi
    resolved="$(try_all docker exec "$name" php-fpm -tt)"
    chk_has "pm = dynamic"          "$resolved" "pm = dynamic"
    chk_has "pm.start_servers"      "$resolved" "pm.start_servers = 4"
    chk_has "pm.min_spare_servers"  "$resolved" "pm.min_spare_servers = 2"
    chk_has "pm.max_spare_servers"  "$resolved" "pm.max_spare_servers = 6"
    # And the pool really did fork that many. A floor rather than an exact
    # count: dynamic is free to add workers, it just may not start with fewer.
    chk_ge "start_servers forked" \
        "$(try docker exec "$name" sh -c 'ps -o args | grep -c "^php-fpm: pool www"')" "4"
    docker rm -f "$name" >/dev/null 2>&1 || true
}

# The -fpm images run two processes, so "the container is up" stops being the
# same question as "the site works". Either death has to stop the container, or
# Docker never restarts it and Apache serves 503s indefinitely.
assert_supervisor() { # <image> <variant> <major>
    local image="$1" variant="$2" major="$3" name rc target pat

    for target in php-fpm httpd; do
        name="sup-${target}-${major}-${STAMP}"
        start "$name" "$image" "$variant"
        if [[ -z "$(probe "$name")" ]]; then
            bad "supervisor ${target}: came up" "no response" "the probe page"
            continue
        fi
        case "$target" in
            php-fpm) pat='php-fpm: master' ;;
            httpd)   pat='httpd -D FOREGROUND' ;;
        esac
        try docker exec "$name" sh -c "kill -9 \$(pgrep -f '${pat}' | head -1)"
        sleep 4
        chk "${target} death stops container" \
            "$(try docker inspect "$name" --format '{{.State.Status}}')" "exited"
        rc="$(try docker inspect "$name" --format '{{.State.ExitCode}}')"
        chk "${target} death exits non-zero" \
            "$( [[ "$rc" != 0 ]] && echo nonzero || echo zero )" "nonzero"
        docker rm -f "$name" >/dev/null 2>&1 || true
    done

    # A normal stop must still be graceful, and must not look like a crash.
    name="sup-stop-${major}-${STAMP}"
    start "$name" "$image" "$variant"
    if [[ -z "$(probe "$name")" ]]; then
        bad "supervisor stop: came up" "no response" "the probe page"
        return
    fi
    try docker stop -t 15 "$name" >/dev/null
    chk "graceful stop exits 0" "$(try docker inspect "$name" --format '{{.State.ExitCode}}')" "0"
    # Counted rather than matched, so a failure reports "0" instead of dumping
    # the whole tail of the container log into the summary.
    chk_ge "graceful stop is clean" "$(try_all docker logs "$name" | grep -c 'bye-bye')" "1"
    docker rm -f "$name" >/dev/null 2>&1 || true
}

# -------------------------------------------------------------- discovery ----
BASE="$(awk '/^FROM /{print $2; exit}' "${DIR}/Dockerfile")"

discover_majors() {
    docker run --rm --entrypoint sh "$BASE" -c \
        "apk update >/dev/null 2>&1; apk search -q '$(variant_probe "$1")' 2>/dev/null" \
        | grep -oE '^php[0-9]+' | sed 's/^php//' | sort -n -u
}

# ------------------------------------------------------------------- main ----
cd "$DIR"
PROBE_CTX="$(build_probe_context)"

for variant in $VARIANTS; do
    if [[ -n "$ONE_IMAGE" ]]; then
        majors="given"
    elif [[ -n "$ONLY_PHP" ]]; then
        majors="$(tr ',' '\n' <<<"$ONLY_PHP" | tr -d ' .' | grep -E '^[0-9]+$' | sort -n -u)"
    else
        majors="$(discover_majors "$variant")"
    fi
    if [[ -z "$majors" ]]; then
        CTX="$variant"; bad "PHP majors to test" "none" "at least one"; continue
    fi

    for major in $majors; do
        head1 "${variant} / php${major}"

        if [[ -n "$ONE_IMAGE" ]]; then
            image="$ONE_IMAGE"
        else
            image="test-${variant}:${major}"
            if (( NO_BUILD )); then
                if ! docker image inspect "$image" >/dev/null 2>&1; then
                    CTX="${variant}/${major}"
                    bad "image present (--no-build)" "missing" "$image"; continue
                fi
            else
                say "  building ${image}"
                if ! docker build -q -f "$(variant_dockerfile "$variant")" \
                        --build-arg "PHP_VER=${major}" -t "$image" . >/dev/null 2>&1; then
                    CTX="${variant}/${major}"
                    bad "image builds" "build failed" "success"; continue
                fi
            fi
        fi

        # Config must validate against the bare image, without the entrypoint
        # having run - that is how a config problem gets diagnosed in the field.
        CTX="${variant}/${major}/config"
        chk_has "httpd -t" "$(try_all docker run --rm --entrypoint httpd "$image" -t)" "Syntax OK"
        if [[ "$variant" == fpm ]]; then
            chk_has "php-fpm -t" \
                "$(try_all docker run --rm --entrypoint php-fpm "$image" -t)" "test is successful"
        fi

        if ! IMAGE_UNDER_TEST="$(probe_image "$image" "$PROBE_CTX")"; then
            CTX="${variant}/${major}"
            bad "probe image builds" "build failed" "success"; continue
        fi

        # ---- pass 1: no environment at all ----
        CTX="${variant}/${major}/defaults"
        head2 "defaults (no -e flags)"
        name="def-${variant}-${major}-${STAMP}"
        start "$name" "$IMAGE_UNDER_TEST" "$variant"
        body="$(probe "$name")"
        if [[ -z "$body" ]]; then
            bad "container serves PHP" "no response" "the probe page"
            try_all docker logs "$name" | tail -5
        else
            say "     PHP $(val "$body" version)"
            assert_serving  "$name" "$body" "$variant"
            assert_defaults "$name" "$body"
        fi
        docker rm -f "$name" >/dev/null 2>&1 || true

        # ---- pass 2: every documented variable overridden ----
        CTX="${variant}/${major}/custom"
        head2 "every documented variable overridden"
        name="cus-${variant}-${major}-${STAMP}"
        if [[ "$variant" == fpm ]]; then venv=("${FPM_ENV[@]}"); else venv=("${MODPHP_ENV[@]}"); fi
        start "$name" "$IMAGE_UNDER_TEST" "$variant" "${COMMON_ENV[@]}" "${venv[@]}"
        body="$(probe "$name")"
        if [[ -z "$body" ]]; then
            bad "container serves PHP" "no response" "the probe page"
            try_all docker logs "$name" | tail -5
        else
            assert_serving "$name" "$body" "$variant"
            assert_custom  "$name" "$body" "$variant"
        fi
        docker rm -f "$name" >/dev/null 2>&1 || true

        # ---- pass 3: the dynamic-only pool settings, -fpm only ----
        if [[ "$variant" == fpm ]]; then
            CTX="${variant}/${major}/pm-dynamic"
            head2 "pm=dynamic pool sizing"
            assert_fpm_dynamic "$IMAGE_UNDER_TEST" "$variant" "$major"

            CTX="${variant}/${major}/missing-tmpfs"
            head2 "missing /run/php-fpm tmpfs is diagnosed"
            assert_missing_tmpfs "$IMAGE_UNDER_TEST" "$major"

            # ---- pass 4: process supervision ----
            CTX="${variant}/${major}/supervisor"
            head2 "supervisor"
            assert_supervisor "$IMAGE_UNDER_TEST" "$variant" "$major"
        fi

        docker rmi -f "$IMAGE_UNDER_TEST" >/dev/null 2>&1 || true
    done
done

printf '\n=============================================\n'
printf ' PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf ' failures:%s\n' "$FAILURES"
    printf '=============================================\n'
    exit 1
fi
printf '=============================================\n'
exit 0
