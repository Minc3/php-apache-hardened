#!/bin/bash
#
# Build php-apache-hardened for every PHP major Alpine ships, in both variants,
# smoke-test each, and push them as version tags.
#
#   menace100/php-apache-hardened:8.3          mod_php  (Dockerfile)
#   menace100/php-apache-hardened:8.4
#   menace100/php-apache-hardened:8.5
#   menace100/php-apache-hardened:stable       -> whichever STABLE_MAJOR names
#   menace100/php-apache-hardened:latest       -> whichever LATEST_MAJOR names
#
#   menace100/php-apache-hardened:8.3-fpm      php-fpm  (Dockerfile.fpm)
#   menace100/php-apache-hardened:8.4-fpm
#   menace100/php-apache-hardened:8.5-fpm
#   menace100/php-apache-hardened:stable-fpm
#   menace100/php-apache-hardened:latest-fpm
#
# The two variants serve the same applications with the same hardening and the
# same mount layout; they differ in how PHP is executed (mpm_prefork + mod_php
# against mpm_event + php-fpm) and therefore in how they are sized. The
# unsuffixed tags remain mod_php, so nothing moves under an existing
# deployment - opting in means changing the tag.
#
# :latest follows the newest PHP major Alpine packages, so pulling with no tag
# hands you the newest PHP - which an older application may not support, and
# which moves on its own when Alpine adds a major. Pin a version tag in
# anything that matters; :latest is a convenience, not a contract.
#
# The version list is discovered from the Alpine repositories rather than
# hardcoded, so a new major appears as a tag on the next run without editing
# anything, and one that is dropped stops being built. Each variant is probed
# separately - a major Alpine packages for mod_php but not FPM, or the reverse,
# simply does not get that tag.
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
#   ./build-all.sh --variant fpm   restrict to one variant (fpm | modphp)
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

# Which major :latest points at. Empty means "the highest major Alpine ships",
# resolved at run time, so a newly packaged major becomes :latest on the next
# run without editing anything. Set it to pin a specific major instead.
LATEST_MAJOR="${LATEST_MAJOR:-}"
LATEST_MAJOR="${LATEST_MAJOR//./}"

# Build for the architecture the servers run, not the machine building.
PLATFORM="${PLATFORM:-linux/amd64}"

LOCK="/tmp/php-apache-hardened-build.lock"

# ------------------------------------------------------------- variants -----
# Everything that differs between the two images, in one place. Adding a third
# variant is a Dockerfile plus four lines here.
ALL_VARIANTS="modphp fpm"

variant_dockerfile() { case "$1" in fpm) echo "Dockerfile.fpm" ;; *) echo "Dockerfile" ;; esac; }
variant_suffix()     { case "$1" in fpm) echo "-fpm"          ;; *) echo ""           ;; esac; }
variant_label()      { case "$1" in fpm) echo "php-fpm"       ;; *) echo "mod_php"    ;; esac; }

# The package that makes a PHP major usable in this variant at all, and so the
# right thing to probe Alpine for. A major without it cannot be built here.
variant_probe()      { case "$1" in fpm) echo "php*-fpm"      ;; *) echo "php*-apache2" ;; esac; }

# What php_sapi_name() must report inside the running container. This is the
# assertion that catches a build which silently fell back to the other
# execution model - a config typo that leaves mod_php loaded, say.
variant_sapi()       { case "$1" in fpm) echo "fpm-fcgi"      ;; *) echo "apache2handler" ;; esac; }

# ------------------------------------------------------------- plumbing -----
# Alpine names its packages php83; the published tags read 8.3. Split on the
# last digit rather than assuming two digits, so a future php100 becomes 10.0
# instead of 1.00.
dotted() { local v="$1"; printf '%s.%s' "${v%?}" "${v##*"${v%?}"}"; }
tag_for() { printf '%s:%s%s' "$REPO" "$(dotted "$2")" "$(variant_suffix "$1")"; }
log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

NO_PUSH=0; LIST_ONLY=0; FORCE=0; CHECK_ONLY=0; ONLY_PHP=""; ONLY_VARIANT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-push) NO_PUSH=1; shift ;;
        --list)    LIST_ONLY=1; shift ;;
        --force)   FORCE=1; shift ;;
        --check)   CHECK_ONLY=1; shift ;;
        --php)     ONLY_PHP="${2:-}"; shift 2 ;;
        --variant) ONLY_VARIANT="${2:-}"; shift 2 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -n "$ONLY_VARIANT" ]]; then
    VARIANTS=""
    for v in $(tr ',' ' ' <<<"$ONLY_VARIANT"); do
        case "$v" in
            fpm|modphp) VARIANTS+="$v " ;;
            mod_php|apache) VARIANTS+="modphp " ;;
            *) die "unknown variant: $v (expected fpm or modphp)" ;;
        esac
    done
else
    VARIANTS="$ALL_VARIANTS"
fi

command -v docker >/dev/null || die "docker not found"
for v in $VARIANTS; do
    [[ -f "${DIR}/$(variant_dockerfile "$v")" ]] \
        || die "no $(variant_dockerfile "$v") in ${DIR}"
done

if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -n 9 || { log "another build holds the lock, exiting"; exit 0; }
fi

BASE="$(awk '/^FROM /{print $2; exit}' "${DIR}/Dockerfile")"
[[ -n "$BASE" ]] || die "could not read the base image from the Dockerfile"

# ------------------------------------------------------------ discovery -----
# Ask Alpine which PHP majors it packages for this variant. A major without the
# variant's key package is useless to that image, so that is the right probe.
discover_majors() {
    local probe; probe="$(variant_probe "$1")"
    docker run --rm --entrypoint sh "$BASE" -c \
        "apk update >/dev/null 2>&1; apk search -q '${probe}' 2>/dev/null" \
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

# Why a published tag would need rebuilding. Echoes the reason and returns 0,
# or returns 1 when it is already current.
needs_build() {
    local variant="$1" major="$2" ref out built_from current
    ref="$(tag_for "$variant" "$major")"

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
# independently: one broken version must not block the others. The container is
# run exactly as the README documents it - non-root, read-only root filesystem,
# tmpfs for the writable paths - so a regression in any of that fails here
# rather than on someone's server.
smoke_test() {
    local img="$1" major="$2" variant="$3" root name rc=0 want_sapi
    want_sapi="$(variant_sapi "$variant")"
    root="${DIR}/.smoke.${variant}.${major}.$$"
    name="smoke-${variant}-${major}-$$"
    mkdir -p "$root/html"
    cat > "$root/html/index.php" <<'PHP'
<?php
$need = ['pdo_mysql','mysqli','session','mbstring','gd','curl','dom','zip','intl','bcmath'];
$missing = array_values(array_filter($need, fn($e) => !extension_loaded($e)));
if ($missing) { http_response_code(500); echo 'MISSING: ', implode(',', $missing); exit; }
if (!extension_loaded('Zend OPcache')) { http_response_code(500); echo 'MISSING: opcache'; exit; }
echo 'SMOKE-OK ', PHP_VERSION, ' ', php_sapi_name();
PHP
    # A file that must never be served, and a .php that does not exist, so the
    # deny rules and the FastCGI guard are covered rather than assumed.
    printf 'must-not-be-served\n' > "$root/html/.env"
    chmod -R a+rX "$root"

    local tmpfs_args=(--tmpfs "/run/apache2:uid=33,gid=33,mode=0755"
                      --tmpfs "/tmp:uid=33,gid=33,mode=1777")
    if [[ "$variant" == fpm ]]; then
        tmpfs_args+=(--tmpfs "/run/php-fpm:uid=33,gid=33,mode=0755")
    fi

    docker run --rm --entrypoint httpd "$img" -t >/dev/null 2>&1 \
        || { log "  php${major}: httpd config invalid"; rm -rf "$root"; return 1; }

    if [[ "$variant" == fpm ]]; then
        docker run --rm --entrypoint php-fpm "$img" -t >/dev/null 2>&1 \
            || { log "  php${major}: php-fpm config invalid"; rm -rf "$root"; return 1; }
    fi

    docker run -d --name "$name" \
        -v "$root:/var/www/:ro" \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --user 33:33 --read-only \
        "${tmpfs_args[@]}" \
        "$img" >/dev/null 2>&1 \
        || { log "  php${major}: container failed to start"; rm -rf "$root"; return 1; }

    local body=""
    for _ in $(seq 1 15); do
        body="$(docker exec "$name" curl -sf http://127.0.0.1/ 2>/dev/null || true)"
        [[ "$body" == SMOKE-OK* ]] && break
        sleep 1
    done

    if [[ "$body" == SMOKE-OK* ]]; then
        # The SAPI must be the one this variant is supposed to run under. A
        # container that serves PHP through the wrong execution model is a
        # broken build even though every response is a 200.
        if [[ "$body" != *"$want_sapi"* ]]; then
            log "  php${major}: wrong SAPI, wanted ${want_sapi} in: ${body}"
            rc=1
        else
            log "  php${major}: ${body#SMOKE-OK }"
        fi
    else
        log "  php${major}: bad response: ${body:-<empty>}"
        rc=1
    fi

    if (( rc == 0 )); then
        local code
        code="$(docker exec "$name" curl -s -o /dev/null -w '%{http_code}' \
                    http://127.0.0.1/.env 2>/dev/null || echo 000)"
        [[ "$code" == 403 ]] || { log "  php${major}: /.env returned ${code}, expected 403"; rc=1; }

        code="$(docker exec "$name" curl -s -o /dev/null -w '%{http_code}' \
                    http://127.0.0.1/index.php/nonexistent.php 2>/dev/null || echo 000)"
        [[ "$code" == 404 ]] || { log "  php${major}: orphan path-info returned ${code}, expected 404"; rc=1; }

        # Both processes have to be up for this to answer, so it doubles as the
        # check that the FPM socket is actually wired to Apache.
        if [[ "$variant" == fpm ]]; then
            local pong
            pong="$(docker exec "$name" curl -sf -A docker-healthcheck \
                        http://127.0.0.1/fpm-ping 2>/dev/null || true)"
            [[ "$pong" == pong ]] || { log "  php${major}: /fpm-ping said '${pong:-<empty>}', expected pong"; rc=1; }
        fi
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$root"
    return $rc
}

# ---------------------------------------------------------------- main ------
cd "$DIR"

BUILT=()      # "variant major", one per successfully built and tested image
FAILED=()
PUSH_TAGS=()

# Build every candidate major for one variant, tag what passes, and move that
# variant's aliases. Each variant is independent: a broken FPM build must not
# stop the mod_php tags from being published, or the reverse.
build_variant() {
    local variant="$1" label dockerfile all_majors majors todo major reason
    label="$(variant_label "$variant")"
    dockerfile="$(variant_dockerfile "$variant")"

    log "=== ${variant} (${label}, ${dockerfile}) ==="
    log "discovering PHP majors in ${BASE} with $(variant_probe "$variant")"
    all_majors="$(discover_majors "$variant")"
    if [[ -z "$all_majors" ]]; then
        log "  no $(variant_probe "$variant") packages found, skipping variant"
        FAILED+=("${variant} (discovery)")
        return 0
    fi
    log "alpine ships: $(tr '\n' ' ' <<<"$all_majors")"

    # Both resolved from the full list, never from a --php subset: building only
    # 85 must not promote 85 to :stable, and building only 83 must not drag
    # :latest back down to 83.
    local stable="$STABLE_MAJOR" latest="$LATEST_MAJOR"
    if [[ -z "$stable" ]]; then
        stable="$(head -1 <<<"$all_majors")"
        log ":stable$(variant_suffix "$variant") resolves to $(dotted "$stable") (lowest major available)"
    else
        log ":stable$(variant_suffix "$variant") pinned to $(dotted "$stable")"
    fi
    if [[ -z "$latest" ]]; then
        latest="$(tail -1 <<<"$all_majors")"
        log ":latest$(variant_suffix "$variant") resolves to $(dotted "$latest") (highest major available)"
    else
        log ":latest$(variant_suffix "$variant") pinned to $(dotted "$latest")"
    fi

    if [[ -n "$ONLY_PHP" ]]; then
        majors="$(tr ',' '\n' <<<"$ONLY_PHP" | tr -d ' .' | grep -E '^[0-9]+$' | sort -n -u)"
        [[ -n "$majors" ]] || die "--php given but no valid majors parsed"
        # Only the ones this variant can actually build.
        majors="$(comm -12 <(sort <<<"$majors") <(sort <<<"$all_majors") | sort -n)"
        [[ -n "$majors" ]] || { log "  none of --php ${ONLY_PHP} are available for ${variant}"; return 0; }
        log "restricted to: $(tr '\n' ' ' <<<"$majors")"
    else
        majors="$all_majors"
    fi

    log "candidates: $(tr '\n' ' ' <<<"$majors")"
    (( LIST_ONLY )) && return 0

    # Filter down to what actually has something new, unless forced.
    if (( FORCE )); then
        log "--force: rebuilding every candidate"
        todo="$majors"
    else
        todo=""
        for major in $majors; do
            if reason="$(needs_build "$variant" "$major")"; then
                log "  php${major}: ${reason}"
                todo+="${major}"$'\n'
            else
                log "  php${major}: up to date"
            fi
        done
        todo="$(sed '/^$/d' <<<"$todo")"
    fi

    if [[ -z "$todo" ]]; then
        log "nothing to do for ${variant}"
        return 0
    fi

    if (( CHECK_ONLY )); then
        log "would rebuild ${variant}: $(tr '\n' ' ' <<<"$todo") (check only)"
        CHECK_WORK=1
        return 0
    fi

    log "will build ${variant}: $(tr '\n' ' ' <<<"$todo")"

    if ! grep -qx "$stable" <<<"$todo"; then
        log "WARNING: ${stable} is not in the ${variant} build list; :stable$(variant_suffix "$variant") will not be updated"
    fi
    if ! grep -qx "$latest" <<<"$todo"; then
        log "WARNING: ${latest} is not in the ${variant} build list; :latest$(variant_suffix "$variant") will not be updated"
    fi

    local variant_built=()
    for major in $todo; do
        log "building php${major} (${variant})"
        local local_tag="php-apache-hardened:build-${variant}-${major}" build_ok

        if docker buildx version >/dev/null 2>&1; then
            build_ok=$(docker buildx build --platform "$PLATFORM" --pull -f "$dockerfile" \
                --build-arg "PHP_VER=${major}" --label "base.digest=$(base_digest)" \
                --load -t "$local_tag" . >/dev/null 2>&1 && echo yes || echo no)
        else
            build_ok=$(docker build --pull -f "$dockerfile" \
                --build-arg "PHP_VER=${major}" --label "base.digest=$(base_digest)" \
                -t "$local_tag" . >/dev/null 2>&1 && echo yes || echo no)
        fi

        if [[ "$build_ok" != yes ]]; then
            log "  php${major}: BUILD FAILED, skipping"
            FAILED+=("${variant} ${major} (build)")
            continue
        fi

        if ! smoke_test "$local_tag" "$major" "$variant"; then
            log "  php${major}: SMOKE TEST FAILED, not tagging"
            FAILED+=("${variant} ${major} (smoke)")
            docker rmi "$local_tag" >/dev/null 2>&1 || true
            continue
        fi

        docker tag "$local_tag" "$(tag_for "$variant" "$major")"
        docker rmi "$local_tag" >/dev/null 2>&1 || true
        variant_built+=("$major")
        BUILT+=("${variant} ${major}")
        PUSH_TAGS+=("$(tag_for "$variant" "$major")")
    done

    [[ ${#variant_built[@]} -gt 0 ]] || { log "nothing built for ${variant}"; return 0; }

    # Move an alias tag onto a major that built this run. An alias is only ever
    # repointed at an image that passed its smoke test; if that major did not
    # build, whatever is published keeps the alias rather than it being dropped
    # or moved onto some other major.
    local alias_name alias_major
    for pair in "stable:$stable" "latest:$latest"; do
        alias_name="${pair%%:*}"; alias_major="${pair##*:}"
        if grep -qx "$alias_major" <<<"$(printf '%s\n' "${variant_built[@]}")"; then
            docker tag "$(tag_for "$variant" "$alias_major")" \
                       "${REPO}:${alias_name}$(variant_suffix "$variant")"
            log "tagged :${alias_name}$(variant_suffix "$variant") from $(dotted "$alias_major")"
            PUSH_TAGS+=("${REPO}:${alias_name}$(variant_suffix "$variant")")
        else
            log "WARNING: ${alias_major} did not build; leaving :${alias_name}$(variant_suffix "$variant") untouched"
        fi
    done
}

CHECK_WORK=0
for variant in $VARIANTS; do
    build_variant "$variant"
done

(( LIST_ONLY )) && exit 0

if (( CHECK_ONLY )); then
    (( CHECK_WORK )) && exit 10
    log "nothing to do"
    exit 0
fi

[[ ${#BUILT[@]} -gt 0 ]] || die "nothing built successfully, nothing to push"

if (( NO_PUSH )); then
    log "--no-push: built and tested ${#BUILT[@]} image(s), nothing pushed"
else
    for tag in ${PUSH_TAGS[@]+"${PUSH_TAGS[@]}"}; do
        log "pushing ${tag}"
        docker push -q "$tag" >/dev/null || die "push of ${tag} failed (docker login?)"
    done
fi

log "built: ${BUILT[*]}"
[[ ${#FAILED[@]} -gt 0 ]] && log "failed: ${FAILED[*]}"
exit 0
