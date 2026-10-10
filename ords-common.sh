# Shared by ords-upgrade.sh and ords-diag.sh: settings, and working out how
# ORDS is installed and run on this server. Keep it next to them; both scripts
# load it from their own directory.
# shellcheck shell=bash
# Globals set here (LAYOUT, POOLS, WAS_ACTIVE, ...) are read by the callers.
# shellcheck disable=SC2034

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m xx\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
#  Settings. load_settings FILE GIVEN - GIVEN is true when the user named FILE
#  with --conf, which makes a missing file an error instead of "use defaults".
# -----------------------------------------------------------------------------
load_settings() {
    CONF="$1"
    if [ -f "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
    elif [ "${2:-false}" = true ]; then
        die "No such settings file: ${CONF}"
    fi

    ORDS_SERVICE="${ORDS_SERVICE:-ords}"
    ORDS_HOME="${ORDS_HOME:-}"
    ORDS_CONFIG="${ORDS_CONFIG:-}"
    ORDS_USER="${ORDS_USER:-}"
    ORDS_JAVA_HOME="${ORDS_JAVA_HOME:-}"
    ORDS_VERSIONS_DIR="${ORDS_VERSIONS_DIR:-}"
    ORDS_POOLS="${ORDS_POOLS:-}"
    ORDS_LOG_FILE="${ORDS_LOG_FILE:-}"
    ORDS_ADMIN_USER="${ORDS_ADMIN_USER:-admin}"
    ORDS_ADMIN_PWD_FILE="${ORDS_ADMIN_PWD_FILE:-}"
    RDS_INSTANCE_ID="${RDS_INSTANCE_ID:-}"
    RDS_SNAPSHOT_TIMEOUT="${RDS_SNAPSHOT_TIMEOUT:-7200}"
    BACKUP_DIR="${BACKUP_DIR:-/var/backups/ords-upgrade}"
    KEEP_VERSIONS="${KEEP_VERSIONS:-3}"
    HEALTH_URLS="${HEALTH_URLS:-}"
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
    ORDS_DOWNLOAD_BASE="${ORDS_DOWNLOAD_BASE:-https://download.oracle.com/otn_software/java/ords}"
}

# -----------------------------------------------------------------------------
#  Small helpers
#
#  Pipelines here never end in 'head' or 'grep -q', which stop reading early:
#  under pipefail the writer then dies of SIGPIPE and a match reads as a
#  failure - but only once the input is big, like a day of ORDS log. Use
#  'sed -n 1p' and here-strings instead.
# -----------------------------------------------------------------------------
unit_prop() { systemctl show "$ORDS_SERVICE" -p "$1" --value 2>/dev/null || true; }

# 26.2.1.r1901402 -> 26.2.1.1901402, so 'sort -V' compares builds numerically.
ver_key() { printf '%s' "$1" | sed 's/\.r\([0-9]\)/.\1/'; }
ver_lt()  { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$(ver_key "$1")" "$(ver_key "$2")" | sort -V | sed -n 1p)" = "$(ver_key "$1")" ]; }

# Run the ords launcher as the service user, with the service's Java. The ORDS
# config and its wallets belong to that user, and an upgrade run as root leaves
# root-owned files behind that the service then cannot read.
ORDS_ENV=()
run_ords() {
    local home="$1"; shift
    local -a cmd=(env "${ORDS_ENV[@]}" "${home}/bin/ords" "$@")
    if [ "$ORDS_USER" = root ]; then
        "${cmd[@]}"
    else
        runuser -u "$ORDS_USER" -- "${cmd[@]}"
    fi
}

# 'ords --version' runs against an empty config, so probing a release can never
# touch the real one. The directory is made here, not inside ords_version():
# that runs in $(...), and a directory created in there would never be cleaned
# up. Callers remove PROBE_CFG on exit.
PROBE_CFG=""
make_probe_dir() {
    PROBE_CFG="$(mktemp -d)"
    chown "$ORDS_USER" "$PROBE_CFG"
}

ords_version_output() { run_ords "$1" --config "$PROBE_CFG" --version 2>&1 || true; }

# "class file version 65.0" -> Java 21. Oracle's error names the class version
# the release was built for, and Java N reads class files up to N + 44.
java_needed_from() {
    printf '%s' "$1" | grep -oE 'class file version [0-9]+' | sed -n 1p | awk '{print $NF - 44}'
}

ords_version() {
    local out need
    out="$(ords_version_output "$1")"
    if grep -q 'UnsupportedClassVersionError' <<<"$out"; then
        need="$(java_needed_from "$out")"
        die "The ORDS in ${1} needs Java ${need:-(newer)} or later; the service's Java is older.
     Install a supported JDK and point the unit at it (or set ORDS_JAVA_HOME)."
    fi
    printf '%s' "$out" | grep -oE 'Oracle REST Data Services [0-9]+\.[0-9]+\.[0-9]+\.r[0-9]+' \
        | awk '{print $NF}' | sed -n 1p
}

# A value from an ORDS config XML file: global settings by default.
config_value() {
    local key="$1" file="${2:-${ORDS_CONFIG}/global/settings.xml}"
    [ -f "$file" ] || return 0
    sed -n "s|.*<entry key=\"${key}\">\(.*\)</entry>.*|\1|p" "$file" | sed -n 1p
}
settings_value() { config_value "$1"; }

# -----------------------------------------------------------------------------
#  Work out what is installed and how it runs
# -----------------------------------------------------------------------------
SERVE_PORT=""
UNIT_ARGS=()
detect() {
    systemctl cat "$ORDS_SERVICE" >/dev/null 2>&1 \
        || die "No systemd unit named '${ORDS_SERVICE}'. Set ORDS_SERVICE in ${CONF}."

    # ExecStart comes back as "{ path=... ; argv[]=/opt/oracle/ords/bin/ords
    # --config /etc/ords/config serve ; ... }".
    local argv i unit_home="" unit_cfg="" unit_java="" unit_user=""
    argv="$(unit_prop ExecStart | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | sed -n 1p)"
    local -a words=()
    read -ra words <<<"$argv"
    UNIT_ARGS=("${words[@]}")
    for ((i = 0; i < ${#words[@]}; i++)); do
        case "${words[$i]}" in
            */bin/ords) unit_home="${words[$i]%/bin/ords}" ;;
            */ords.war) unit_home="$(dirname "${words[$i]}")" ;;
            --config)   unit_cfg="${words[$((i + 1))]:-}" ;;
            --config=*) unit_cfg="${words[$i]#--config=}" ;;
            --port)     SERVE_PORT="${words[$((i + 1))]:-}" ;;
        esac
    done

    # Environment= and EnvironmentFile= are where units usually set these.
    local w f
    read -ra words <<<"$(unit_prop Environment)"
    for w in "${words[@]}"; do
        case "$w" in
            JAVA_HOME=*)   unit_java="${w#JAVA_HOME=}" ;;
            ORDS_CONFIG=*) unit_cfg="${unit_cfg:-${w#ORDS_CONFIG=}}" ;;
        esac
    done
    while read -r f _; do
        [ -r "$f" ] || continue
        w="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}JAVA_HOME=["'\'']\{0,1\}\([^"'\'']*\).*/\2/p' "$f" | tail -1)"
        unit_java="${unit_java:-$w}"
        w="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}ORDS_CONFIG=["'\'']\{0,1\}\([^"'\'']*\).*/\2/p' "$f" | tail -1)"
        unit_cfg="${unit_cfg:-$w}"
    done <<<"$(unit_prop EnvironmentFiles)"

    if rpm -q ords >/dev/null 2>&1; then
        LAYOUT=rpm
        ORDS_HOME="${ORDS_HOME:-$(dirname "$(rpm -ql ords | grep '/ords\.war$' | sed -n 1p)")}"
        # The RPM's unit runs /etc/init.d/ords, which takes its settings from
        # /etc/ords.conf, runs ORDS as the owner of bin/ords, and sends its
        # output to a log file rather than the journal.
        if [ -r /etc/ords.conf ]; then
            w="$(sed -n 's/^ORDS_CONFIG=\([^#]*\).*/\1/p' /etc/ords.conf | tail -1)"
            unit_cfg="${unit_cfg:-$w}"
            w="$(sed -n 's/^JAVA_HOME=\([^#]*\).*/\1/p' /etc/ords.conf | tail -1)"
            unit_java="${unit_java:-$w}"
            read -ra words <<<"$(sed -n 's/^SERVE_EXTRA_ARGS=\([^#]*\).*/\1/p' /etc/ords.conf | tail -1)"
            UNIT_ARGS+=("${words[@]}")
            for ((i = 0; i < ${#words[@]}; i++)); do
                [ "${words[$i]}" = --port ] && SERVE_PORT="${words[$((i + 1))]:-}"
            done
        fi
        unit_user="$(unit_prop User)"
        [ -n "$unit_user" ] || unit_user="$(stat -c %U "${ORDS_HOME}/bin/ords")"
        ORDS_LOG_FILE="${ORDS_LOG_FILE:-/var/log/ords/ords.log}"
    else
        ORDS_HOME="${ORDS_HOME:-$unit_home}"
        [ -n "$ORDS_HOME" ] || die "Could not tell where ORDS is installed from unit '${ORDS_SERVICE}'.
     Its ExecStart is: ${argv:-(empty)}
     Set ORDS_HOME in ${CONF} to the directory holding bin/ords."
        if [ -L "$ORDS_HOME" ]; then
            LAYOUT=symlink
        elif [ -d "$ORDS_HOME" ]; then
            LAYOUT=plain
        else
            die "ORDS_HOME ${ORDS_HOME} does not exist."
        fi
    fi
    [ -x "${ORDS_HOME}/bin/ords" ] || die "No ${ORDS_HOME}/bin/ords - is ORDS_HOME right?"
    ORDS_REAL="$(readlink -f "$ORDS_HOME")"

    ORDS_CONFIG="${ORDS_CONFIG:-$unit_cfg}"
    [ -n "$ORDS_CONFIG" ] || die "Could not find the ORDS configuration directory.
     The unit passes no --config and sets no ORDS_CONFIG. Set ORDS_CONFIG in ${CONF}."
    [ -d "${ORDS_CONFIG}/databases" ] || die "${ORDS_CONFIG} has no databases/ - is ORDS_CONFIG right?"
    ORDS_CONFIG="$(readlink -f "$ORDS_CONFIG")"

    [ "$LAYOUT" = rpm ] || unit_user="$(unit_prop User)"
    ORDS_USER="${ORDS_USER:-${unit_user:-root}}"
    id "$ORDS_USER" >/dev/null 2>&1 || die "ORDS_USER ${ORDS_USER} does not exist."

    ORDS_JAVA_HOME="${ORDS_JAVA_HOME:-$unit_java}"
    ORDS_ENV=("ORDS_CONFIG=${ORDS_CONFIG}")
    if [ -n "$ORDS_JAVA_HOME" ]; then
        ORDS_ENV+=("JAVA_HOME=${ORDS_JAVA_HOME}" "PATH=${ORDS_JAVA_HOME}/bin:${PATH}")
    fi

    ORDS_VERSIONS_DIR="${ORDS_VERSIONS_DIR:-$(dirname "$ORDS_HOME")/ords-versions}"

    # A unit with StandardOutput=append:/path logs to that file, not the journal.
    if [ -z "$ORDS_LOG_FILE" ]; then
        case "$(unit_prop StandardOutput)" in
            file:*|append:*|truncate:*) ORDS_LOG_FILE="$(unit_prop StandardOutput)"; ORDS_LOG_FILE="${ORDS_LOG_FILE#*:}" ;;
        esac
    fi

    POOLS=()
    local p
    if [ -n "$ORDS_POOLS" ]; then
        for p in ${ORDS_POOLS//,/ }; do
            [ -f "${ORDS_CONFIG}/databases/${p}/pool.xml" ] || die "ORDS_POOLS names '${p}', which has no pool.xml in ${ORDS_CONFIG}/databases."
            POOLS+=("$p")
        done
    else
        while read -r p; do
            [ -n "$p" ] && POOLS+=("$(basename "$(dirname "$p")")")
        done < <(find "${ORDS_CONFIG}/databases" -mindepth 2 -maxdepth 2 -name pool.xml | sort)
    fi

    if systemctl is-active --quiet "$ORDS_SERVICE"; then WAS_ACTIVE=true; else WAS_ACTIVE=false; fi
}

# Swapping the directory ORDS_HOME points at loses anything kept inside it.
# Configuration and APEX static files are the two things people put there, by
# either path - through the symlink or the directory it points at.
check_nothing_lives_in_home() {
    [ "$LAYOUT" = rpm ] && return 0
    case "${ORDS_CONFIG}/" in
        "${ORDS_REAL}/"*|"${ORDS_HOME}/"*)
            die "The ORDS configuration (${ORDS_CONFIG}) is inside the ORDS install
     directory, so switching to a new release would leave it behind. Move it out
     first, e.g. to /etc/ords/config, update --config in the unit, and rerun." ;;
    esac
    local hits="" prefix w
    for prefix in "$ORDS_REAL" "$ORDS_HOME"; do
        hits+="$(grep -rhoE "<entry key=\"[^\"]+\">${prefix//./\\.}/[^<]*" "$ORDS_CONFIG" --include='*.xml' \
                 | sed 's/<entry key="\([^"]*\)">/\1 = /' || true)"$'\n'
        for w in "${UNIT_ARGS[@]}"; do
            case "$w" in
                "${prefix}/bin/ords"|"${prefix}/ords.war") ;;
                "${prefix}/"*) hits+="service argument ${w}"$'\n' ;;
            esac
        done
    done
    hits="$(printf '%s' "$hits" | grep -v '^$' | sort -u || true)"
    [ -z "$hits" ] || die "These point inside the ORDS install directory, which a new release
     replaces. Move what they point at somewhere stable first:
$(printf '%s\n' "$hits" | sed 's/^/       /')"

    if [ "$LAYOUT" = plain ] && [[ $(basename "$ORDS_HOME") =~ [0-9]+\.[0-9]+ ]]; then
        die "ORDS_HOME (${ORDS_HOME}) is named after a version, so it cannot become the
     stable symlink that later upgrades switch. Give the unit a stable path once:
       ln -s ${ORDS_HOME} $(dirname "$ORDS_HOME")/ords
       edit ExecStart in the unit to use $(dirname "$ORDS_HOME")/ords/bin/ords
       systemctl daemon-reload && systemctl restart ${ORDS_SERVICE}
     then rerun ords-upgrade.sh."
    fi
}

# -----------------------------------------------------------------------------
#  Where ORDS answers
# -----------------------------------------------------------------------------
# scheme://127.0.0.1:port, from --port, then the standalone settings.
ords_origin() {
    local http https
    http="${SERVE_PORT:-$(settings_value standalone.http.port)}"
    https="$(settings_value standalone.https.port)"
    if [ -n "$http" ]; then
        printf 'http://127.0.0.1:%s' "$http"
    elif [ -n "$https" ]; then
        printf 'https://127.0.0.1:%s' "$https"
    else
        printf 'http://127.0.0.1:8080'
    fi
}

ords_context() {
    local ctx
    ctx="$(settings_value standalone.context.path)"
    printf '%s' "${ctx:-/ords}"
}

default_health_urls() { printf '%s%s/' "$(ords_origin)" "$(ords_context)"; }

# The table ORDS prints once it has read its pools, one line per pool:
#   /ords/    => default    => VALID
pool_table() { grep -E '=>.*=> *[A-Z]+ *$' || true; }

# -----------------------------------------------------------------------------
#  Getting a release
# -----------------------------------------------------------------------------
# The zip for a build. Oracle names it from the build number that
# 'ords --version' prints: r1901402 is day 190, 14:02, so ords-26.2.1.190.1402.zip.
zip_name_for() {
    local v="$1"
    if [[ $v =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.r([0-9]{2,3})([0-9]{4})$ ]]; then
        printf 'ords-%s.%s.%s.zip' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    elif [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'ords-%s.zip' "$v"
    else
        return 1
    fi
}

# Reuses an earlier download when Oracle's ETag has not changed, so a dry run
# followed by the real run downloads ~200 MB once, not twice.
download() {
    local url="$1" out="$2" etag
    etag="$(curl -fsIL --max-time 30 "$url" | tr -d '\r' | awk 'tolower($1)=="etag:"{v=$2} END{print v}')" \
        || die "Cannot reach ${url}. For a server without internet access, download it
     elsewhere and pass --zip."
    [ -n "$etag" ] || die "${url} does not exist. Check the version, or pass --zip."
    if [ -f "$out" ] && [ "$(cat "${out}.etag" 2>/dev/null)" = "$etag" ]; then
        ok "Using the copy already downloaded: ${out}"
        return 0
    fi
    log "Downloading ${url}"
    local -a progress=(-sS)
    [ -t 1 ] && progress=(--progress-bar)
    curl -fL --retry 3 "${progress[@]}" -o "${out}.part" "$url" || die "Download failed: ${url}"
    mv "${out}.part" "$out"
    printf '%s' "$etag" >"${out}.etag"
}

# -----------------------------------------------------------------------------
#  Is a freshly started ORDS healthy?
# -----------------------------------------------------------------------------
# What ORDS has logged since start_and_check() started it: the journal for this
# run of the unit, or the part of ORDS_LOG_FILE written since.
startup_log() {
    if [ -n "$ORDS_LOG_FILE" ]; then
        [ -r "$ORDS_LOG_FILE" ] || return 0
        local size
        size="$(stat -c %s "$ORDS_LOG_FILE")"
        # Rotated or truncated since we looked: it is all new.
        [ "$size" -ge "${LOG_OFFSET:-0}" ] || LOG_OFFSET=0
        tail -c +"$(( ${LOG_OFFSET:-0} + 1 ))" "$ORDS_LOG_FILE"
    else
        journalctl -u "$ORDS_SERVICE" "_SYSTEMD_INVOCATION_ID=$(unit_prop InvocationID)" \
            -o cat --no-pager -q 2>/dev/null || true
    fi
}

# ORDS reads its pools at startup and prints a table of them, ending with
# "Oracle REST Data Services initialized":
#
#   /ords/    => default    => VALID
#
# That table is the real test. HTTP alone is not: ORDS starts listening a few
# seconds before it checks the pools, and '/ords/' answers 302 even when every
# pool is INVALID - only requests that need the database return errors (574).
pools_valid() {
    local out bad deadline=$((SECONDS + HEALTH_TIMEOUT))
    if [ -z "$ORDS_LOG_FILE" ]; then
        case "$(unit_prop StandardOutput)" in
            journal*|inherit|kmsg*) ;;
            *) warn "Cannot find where ${ORDS_SERVICE} logs, so pool status is not checked. Set ORDS_LOG_FILE."; return 0 ;;
        esac
    fi
    while :; do
        out="$(startup_log)"
        if grep -q 'REST Data Services initialized' <<<"$out"; then
            bad="$(printf '%s\n' "$out" | pool_table | grep -vE '=> *VALID *$' || true)"
            if [ -n "$bad" ]; then
                warn "ORDS started, but not every pool can reach its database:"
                printf '%s\n' "$bad" | sed 's/^ */       /' >&2
                return 1
            fi
            ok "All pools VALID"
            return 0
        fi
        if ! systemctl is-active --quiet "$ORDS_SERVICE"; then
            warn "The ${ORDS_SERVICE} service stopped while starting. See: journalctl -u ${ORDS_SERVICE}"
            return 1
        fi
        [ "$SECONDS" -lt "$deadline" ] || { warn "ORDS did not log that it had finished starting within ${HEALTH_TIMEOUT}s."; return 1; }
        sleep 3
    done
}

healthy() {
    pools_valid || return 1
    local url code state deadline=$((SECONDS + HEALTH_TIMEOUT))
    for url in $HEALTH_URLS; do
        while :; do
            state="$(systemctl is-active "$ORDS_SERVICE" 2>/dev/null || true)"
            if [ "$state" = failed ] || [ "$state" = inactive ]; then
                warn "The ${ORDS_SERVICE} service is ${state}. See: journalctl -u ${ORDS_SERVICE}"
                return 1
            fi
            code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
            case "$code" in
                2??|3??) ok "${url} answers HTTP ${code}"; break ;;
            esac
            if [ "$SECONDS" -ge "$deadline" ]; then
                warn "${url} did not answer healthily within ${HEALTH_TIMEOUT}s (last HTTP ${code:-none})"
                return 1
            fi
            sleep 5
        done
    done
}
