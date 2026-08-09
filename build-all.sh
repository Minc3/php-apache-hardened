#!/bin/bash
#
# Build php-apache-hardened for every PHP major Alpine ships, smoke-test each,
# and push them as version tags.
#
#   menace100/php-apache-hardened:8.3
#   menace100/php-apache-hardened:8.4
#   menace100/php-apache-hardened:8.5
#   menace100/php-apache-hardened:stable   -> whichever STABLE_MAJOR names
#
# There is deliberately no :latest tag. Pulling with no tag fails rather
# than silently handing someone a PHP major their application may not
# support - the version is always an explicit choice.
#
# The version list is discovered from the Alpine repositories rather than
# hardcoded, so a new major appears as a tag on the next run without editing
# anything, and one that is dropped stops being built.
#
# By default only majors that actually have something new are rebuilt, so this
# is safe to run daily from cron: a run with nothing to do costs a few seconds
# and pushes nothing.
#
#   ./build-all.sh                 rebuild + push only what is stale
#   ./build-all.sh --force         rebuild every major regardless
#   ./build-all.sh --check         report only, never build (exit 10 = work to do)
#   ./build-all.sh --no-push       build and test only
#   ./build-all.sh --php 8.4,8.5   restrict to specific majors (84,85 also accepted)
#   ./build-all.sh --list          show what would be built, then exit
#
# Requires a prior `docker login`.
#
# Cron (daily 04:20):
#   20 4 * * * /path/to/build-all.sh >> /var/log/php-apache-hardened.log 2>&1

set -euo pipefail

# ---------------------------------------------------------------- config ----
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-menace100/php-apache-hardened}"

# Which major :stable points at. Empty means "the lowest major Alpine ships",
# resolved at run time - that is the oldest still-packaged PHP, which has the
# widest application support, and it moves on its own when Alpine drops one.
# Set it to pin a specific major instead, e.g. STABLE_MAJOR=84.
STABLE_MAJOR="${STABLE_MAJOR:-}"
STABLE_MAJOR="${STABLE_MAJOR//./}"   # accept 8.4 or 84

# Build for the architecture the servers run, not the machine building.
PLATFORM="${PLATFORM:-linux/amd64}"

LOCK="/tmp/php-apache-hardened-build.lock"

# ------------------------------------------------------------- plumbing -----
# Alpine names its packages php83; the published tags read 8.3. Split on the
# last digit rather than assuming two digits, so a future php100 becomes 10.0
# instead of 1.00.
dotted() { local v="$1"; printf '%s.%s' "${v%?}" "${v##*"${v%?}"}"; }
log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

NO_PUSH=0; LIST_ONLY=0; FORCE=0; CHECK_ONLY=0; ONLY_PHP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-push) NO_PUSH=1; shift ;;
        --list)    LIST_ONLY=1; shift ;;
        --force)   FORCE=1; shift ;;
        --check)   CHECK_ONLY=1; shift ;;
        --php)     ONLY_PHP="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

command -v docker >/dev/null || die "docker not found"
[[ -f "${DIR}/Dockerfile" ]] || die "no Dockerfile in ${DIR}"

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -n 9 || { log "another build holds the lock, exiting"; exit 0; }
fi

BASE="$(awk '/^FROM /{print $2; exit}' "${DIR}/Dockerfile")"
[[ -n "$BASE" ]] || die "could not read the base image from the Dockerfile"

# ------------------------------------------------------------ discovery -----
# Ask Alpine which PHP majors it packages with an Apache module. A major
# without phpNN-apache2 is useless to this image, so that is the right probe.
discover_majors() {
    docker run --rm --entrypoint sh "$BASE" -c \
        'apk update >/dev/null 2>&1; apk search -q "php*-apache2" 2>/dev/null' \
        | grep -oE '^php[0-9]+' | sed 's/^php//' | sort -n -u
}

# ----------------------------------------------------- update detection -----
# Current digest of the base image, resolved from the registry. Stamped onto
# every build as a label, so staleness is a fact about the published image
# rather than about this machine's pull history.
BASE_DIGEST=""
base_digest() {
    if [[ -z "$BASE_DIGEST" ]]; then
        docker pull -q "$BASE" >/dev/null 2>&1 || true
        BASE_DIGEST="$(docker image inspect "$BASE" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "")"
    fi
    printf '%s' "$BASE_DIGEST"
}

# Why a published major would need rebuilding. Echoes the reason and returns 0,
# or returns 1 when it is already current.
needs_build() {
    local major="$1" ref out built_from current
    ref="${REPO}:$(dotted "$major")"

    if ! docker pull -q "$ref" >/dev/null 2>&1; then
        echo "not published yet"; return 0
    fi

    # Ask the published image what it would upgrade - exactly the question
    # "is what I shipped now stale". --simulate changes nothing.
    out="$(docker run --rm --entrypoint sh "$ref" -c \
            'apk update >/dev/null 2>&1 && apk upgrade --simulate 2>&1' || true)"
    # apk prints "(1/10) Upgrading musl (...)", so this must not be anchored.
    if grep -qE '\bUpgrading ' <<<"$out"; then
        echo "$(grep -cE '\bUpgrading ' <<<"$out") package update(s)"; return 0
    fi

    built_from="$(docker image inspect "$ref" \
        --format '{{index .Config.Labels "base.digest"}}' 2>/dev/null || echo "")"
    current="$(base_digest)"
    if [[ -z "$built_from" ]]; then
        echo "no base.digest label"; return 0
    fi
    if [[ -n "$current" && "$built_from" != "$current" ]]; then
        echo "base image moved"; return 0
    fi

    return 1
}

# ---------------------------------------------------------- smoke tests -----
# Nothing is pushed unless it can actually serve PHP. Each major is tested
# independently: one broken version must not block the others.
smoke_test() {
    local img="$1" major="$2" root name rc=0
    root="${DIR}/.smoke.${major}.$$"
    name="smoke-${major}-$$"
    mkdir -p "$root/html"
    cat > "$root/html/index.php" <<'PHP'
<?php
$need = ['pdo_mysql','mysqli','session','mbstring','gd','curl','dom','zip','intl','bcmath'];
$missing = array_values(array_filter($need, fn($e) => !extension_loaded($e)));
if ($missing) { http_response_code(500); echo 'MISSING: ', implode(',', $missing); exit; }
if (!extension_loaded('Zend OPcache')) { http_response_code(500); echo 'MISSING: opcache'; exit; }
echo 'SMOKE-OK ', PHP_VERSION;
PHP
    chmod -R a+rX "$root"

    docker run --rm --entrypoint httpd "$img" -t >/dev/null 2>&1 \
        || { log "  php${major}: httpd config invalid"; rm -rf "$root"; return 1; }

    docker run -d --name "$name" \
        -v "$root:/var/www/:ro" \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --user 33:33 --read-only \
        --tmpfs /run/apache2:uid=33,gid=33,mode=0755 \
        --tmpfs /tmp:uid=33,gid=33,mode=1777 \
        "$img" >/dev/null 2>&1 \
        || { log "  php${major}: container failed to start"; rm -rf "$root"; return 1; }

    local body=""
    for _ in $(seq 1 15); do
        body="$(docker exec "$name" curl -sf http://127.0.0.1/ 2>/dev/null || true)"
        [[ "$body" == SMOKE-OK* ]] && break
        sleep 1
    done
    if [[ "$body" == SMOKE-OK* ]]; then
        log "  php${major}: ${body#SMOKE-OK }"
    else
        log "  php${major}: bad response: ${body:-<empty>}"
        rc=1
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$root"
    return $rc
}

# ---------------------------------------------------------------- main ------
cd "$DIR"

log "discovering PHP majors in ${BASE}"
ALL_MAJORS="$(discover_majors)"
[[ -n "$ALL_MAJORS" ]] || die "no phpNN-apache2 packages found in ${BASE}"
log "alpine ships: $(tr '\n' ' ' <<<"$ALL_MAJORS")"

# Resolved from the full list, never from a --php subset: building only 85
# must not promote 85 to :stable.
if [[ -z "$STABLE_MAJOR" ]]; then
    STABLE_MAJOR="$(head -1 <<<"$ALL_MAJORS")"
    log ":stable resolves to $(dotted "$STABLE_MAJOR") (lowest major available)"
else
    log ":stable pinned to $(dotted "$STABLE_MAJOR")"
fi

if [[ -n "$ONLY_PHP" ]]; then
    MAJORS="$(tr ',' '\n' <<<"$ONLY_PHP" | tr -d ' .' | grep -E '^[0-9]+$' | sort -n -u)"
    [[ -n "$MAJORS" ]] || die "--php given but no valid majors parsed"
    log "restricted to: $(tr '\n' ' ' <<<"$MAJORS")"
else
    MAJORS="$ALL_MAJORS"
fi

log "candidates: $(tr '\n' ' ' <<<"$MAJORS")"
(( LIST_ONLY )) && exit 0

# Filter down to what actually has something new, unless forced.
if (( FORCE )); then
    log "--force: rebuilding every candidate"
    TODO="$MAJORS"
else
    TODO=""
    for major in $MAJORS; do
        if reason="$(needs_build "$major")"; then
            log "  php${major}: ${reason}"
            TODO+="${major}"$'\n'
        else
            log "  php${major}: up to date"
        fi
    done
    TODO="$(sed '/^$/d' <<<"$TODO")"
fi

if [[ -z "$TODO" ]]; then
    log "nothing to do"
    exit 0
fi

if (( CHECK_ONLY )); then
    log "would rebuild: $(tr '\n' ' ' <<<"$TODO") (check only)"
    exit 10
fi

MAJORS="$TODO"
log "will build: $(tr '\n' ' ' <<<"$MAJORS")"

if ! grep -qx "$STABLE_MAJOR" <<<"$MAJORS"; then
    log "WARNING: STABLE_MAJOR=${STABLE_MAJOR} is not in the build list; :stable will not be updated"
fi

BUILT=(); FAILED=()

for major in $MAJORS; do
    log "building php${major}"
    local_tag="php-apache-hardened:build-${major}"

    if docker buildx version >/dev/null 2>&1; then
        build_ok=$(docker buildx build --platform "$PLATFORM" --pull \
            --build-arg "PHP_VER=${major}" --label "base.digest=$(base_digest)" \
            --load -t "$local_tag" . >/dev/null 2>&1 && echo yes || echo no)
    else
        build_ok=$(docker build --pull \
            --build-arg "PHP_VER=${major}" --label "base.digest=$(base_digest)" \
            -t "$local_tag" . >/dev/null 2>&1 && echo yes || echo no)
    fi

    if [[ "$build_ok" != yes ]]; then
        log "  php${major}: BUILD FAILED, skipping"
        FAILED+=("$major (build)")
        continue
    fi

    if ! smoke_test "$local_tag" "$major"; then
        log "  php${major}: SMOKE TEST FAILED, not tagging"
        FAILED+=("$major (smoke)")
        docker rmi "$local_tag" >/dev/null 2>&1 || true
        continue
    fi

    docker tag "$local_tag" "${REPO}:$(dotted "$major")"
    docker rmi "$local_tag" >/dev/null 2>&1 || true
    BUILT+=("$major")
done

[[ ${#BUILT[@]} -gt 0 ]] || die "nothing built successfully, nothing to push"

if grep -qx "$STABLE_MAJOR" <<<"$(printf '%s\n' "${BUILT[@]}")"; then
    docker tag "${REPO}:$(dotted "$STABLE_MAJOR")" "${REPO}:stable"
    log "tagged :stable from $(dotted "$STABLE_MAJOR")"
else
    log "WARNING: ${STABLE_MAJOR} did not build; leaving :stable untouched"
fi

if (( NO_PUSH )); then
    log "--no-push: built and tested ${BUILT[*]}, nothing pushed"
else
    for major in "${BUILT[@]}"; do
        log "pushing ${REPO}:$(dotted "$major")"
        docker push -q "${REPO}:$(dotted "$major")" >/dev/null || die "push failed (docker login?)"
    done
    if grep -qx "$STABLE_MAJOR" <<<"$(printf '%s\n' "${BUILT[@]}")"; then
        log "pushing ${REPO}:stable"
        docker push -q "${REPO}:stable" >/dev/null || die "push of :stable failed"
    fi
fi

log "built: ${BUILT[*]}"
[[ ${#FAILED[@]} -gt 0 ]] && log "failed: ${FAILED[*]}"
exit 0
