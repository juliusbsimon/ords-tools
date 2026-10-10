#!/usr/bin/env bash
# Health and upgrade-readiness report for an ORDS server that runs under
# systemd. Read-only: it downloads nothing, logs into no database, and never
# starts, stops or edits anything. Safe for a person or an agent to run at any
# time, including to decide whether to run ords-upgrade.sh.
#
#   ./ords-diag.sh             # report
#   ./ords-diag.sh --json      # the same checks as JSON
#
# Options:
#   -c, --conf FILE   settings file (default /etc/ords-upgrade.conf)
#   --json            print JSON instead of the report
#   --offline         skip the two checks that leave this server: a HEAD request
#                     to Oracle's download site, and 'aws rds describe-db-instances'
#   --lines N         how much log to scan when there is no single startup to
#                     read (default 2000)
#
# Every check has a stable id and one status:
#   PASS  fine    WARN  worth reading first    FAIL  fix before upgrading    INFO  context
#
# The last line is a verdict on running ords-upgrade.sh now:
#   READY                  nothing in the way
#   READY_WITH_WARNINGS    it will run; read the WARN lines first
#   NOT_READY              a FAIL will stop the upgrade or make it roll back
#
# Exit status: 0 READY, 1 READY_WITH_WARNINGS, 2 NOT_READY.
#
# Run as root: the ORDS config, the journal and the service user's view of the
# files are not readable otherwise. Needs ords-common.sh beside it; both come
# from https://github.com/juliusbsimon/ords-tools.
#
# No 'set -e': a diagnostic has to carry on past the thing that is broken.
set -uo pipefail

# shellcheck source=SCRIPTDIR/ords-common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ords-common.sh" \
    || { echo "ords-common.sh must be in the same directory as this script" >&2; exit 2; }

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

CONF=/etc/ords-upgrade.conf
CONF_GIVEN=false
JSON=false
OFFLINE=false
SCAN_LINES=2000

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--conf) CONF="${2:?--conf needs a file}"; CONF_GIVEN=true; shift 2 ;;
        --json)    JSON=true; shift ;;
        --offline) OFFLINE=true; shift ;;
        --lines)   SCAN_LINES="${2:?--lines needs a number}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         die "Unknown option: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo): the ORDS config, the journal and the service user's
     view of the files are not readable otherwise. Nothing is changed."
load_settings "$CONF" "$CONF_GIVEN"
cd /

COOKIES=""
trap 'rm -rf "$PROBE_CFG" "$COOKIES"' EXIT

# -----------------------------------------------------------------------------
#  Recording results
# -----------------------------------------------------------------------------
CHECK_IDS=(); CHECK_STATUS=(); CHECK_SUMMARY=(); CHECK_DETAIL=()
FACT_KEYS=(); FACT_VALUES=()

if [ -t 1 ] && [ "$JSON" = false ]; then
    C_PASS=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'; C_INFO=$'\033[1;34m'; C_OFF=$'\033[0m'
else
    C_PASS=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_OFF=""
fi

# Colour codes and the ' xx ' prefix from die(), so captured messages read cleanly.
clean() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g' | sed 's/^ *xx *//; s/^ *!! *//'; }

section() { [ "$JSON" = true ] || printf '\n== %s\n' "$1"; }

# check ID STATUS SUMMARY [DETAIL]
check() {
    local id="$1" status="$2" summary="$3" detail="${4:-}" colour
    CHECK_IDS+=("$id"); CHECK_STATUS+=("$status"); CHECK_SUMMARY+=("$summary"); CHECK_DETAIL+=("$detail")
    [ "$JSON" = true ] && return 0
    case "$status" in
        PASS) colour="$C_PASS" ;; WARN) colour="$C_WARN" ;; FAIL) colour="$C_FAIL" ;; *) colour="$C_INFO" ;;
    esac
    printf '%s%-4s%s  %-30s %s\n' "$colour" "$status" "$C_OFF" "$id" "$summary"
    [ -z "$detail" ] || printf '%s\n' "$detail" | sed 's/^/        /'
}

fact() {
    FACT_KEYS+=("$1"); FACT_VALUES+=("$2")
    [ "$JSON" = true ] || printf '      %-30s %s\n' "$1" "$2"
}

json_str() {
    local s
    s="$(clean "$1")"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
}

finish() {
    local i fails=0 warns=0 verdict code
    for i in "${!CHECK_STATUS[@]}"; do
        case "${CHECK_STATUS[$i]}" in FAIL) fails=$((fails + 1)) ;; WARN) warns=$((warns + 1)) ;; esac
    done
    if [ "$fails" -gt 0 ]; then verdict=NOT_READY; code=2
    elif [ "$warns" -gt 0 ]; then verdict=READY_WITH_WARNINGS; code=1
    else verdict=READY; code=0; fi

    if [ "$JSON" = true ]; then
        printf '{\n  "tool": "ords-diag", "format": 1,\n'
        printf '  "host": %s, "time": %s,\n' "$(json_str "$(uname -n)")" "$(json_str "$(date -Is)")"
        printf '  "verdict": "%s", "fails": %d, "warns": %d,\n  "facts": {' "$verdict" "$fails" "$warns"
        for i in "${!FACT_KEYS[@]}"; do
            [ "$i" -eq 0 ] || printf ','
            printf '\n    %s: %s' "$(json_str "${FACT_KEYS[$i]}")" "$(json_str "${FACT_VALUES[$i]}")"
        done
        printf '\n  },\n  "checks": ['
        for i in "${!CHECK_IDS[@]}"; do
            [ "$i" -eq 0 ] || printf ','
            printf '\n    {"id": %s, "status": "%s", "summary": %s, "detail": %s}' \
                "$(json_str "${CHECK_IDS[$i]}")" "${CHECK_STATUS[$i]}" \
                "$(json_str "${CHECK_SUMMARY[$i]}")" "$(json_str "${CHECK_DETAIL[$i]}")"
        done
        printf '\n  ]\n}\n'
    else
        echo
        printf '%d FAIL, %d WARN.  Verdict: %s\n' "$fails" "$warns" "$verdict"
        case "$verdict" in
            NOT_READY) echo "Fix the FAIL lines before running ords-upgrade.sh." ;;
            *)         echo "Next: ords-upgrade.sh --dry-run downloads the new release and prints the plan, changing nothing else." ;;
        esac
    fi
    exit "$code"
}

# -----------------------------------------------------------------------------
#  Pieces used by several checks
# -----------------------------------------------------------------------------
# Free MB on the filesystem holding a path, or its nearest existing parent.
free_mb() {
    local p="$1"
    while [ ! -e "$p" ] && [ "$p" != / ]; do p="$(dirname "$p")"; done
    df -Pm "$p" 2>/dev/null | awk 'NR==2{print $4}'
}

# The log of the most recent start: this run of the unit in the journal, or
# ORDS_LOG_FILE from its last "ORDS: Release" banner on.
last_start_log() {
    if [ -n "$ORDS_LOG_FILE" ]; then
        [ -r "$ORDS_LOG_FILE" ] || return 0
        tail -n 200000 "$ORDS_LOG_FILE" | awk '/ORDS: Release [0-9]/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}'
    else
        local inv
        inv="$(unit_prop InvocationID)"
        if [ -n "$inv" ]; then
            journalctl -u "$ORDS_SERVICE" "_SYSTEMD_INVOCATION_ID=${inv}" -o cat --no-pager -q 2>/dev/null
        else
            journalctl -u "$ORDS_SERVICE" -n "$SCAN_LINES" -o cat --no-pager -q 2>/dev/null
        fi
    fi
}

# One line of advice for the Oracle errors that account for most INVALID pools.
ora_hint() {
    case "$1" in
        *ORA-01017*) echo "Wrong username or password. For the pool's own user (usually ORDS_PUBLIC_USER) the wallet and the database disagree." ;;
        *ORA-28000*) echo "The database account is locked." ;;
        *ORA-28001*) echo "The database account's password has expired." ;;
        *ORA-12514*) echo "The listener does not know that service name - check db.servicename." ;;
        *ORA-12541*|*ORA-12170*|*"IO Error"*|*"Connection refused"*|*"timed out"*)
                     echo "Network: ORDS cannot reach the listener. On RDS, check the security group allows this server." ;;
        *ORA-01031*) echo "Missing privileges. On RDS, the master user needs the grants AWS lists for ORDS." ;;
    esac
}

pool_file() { printf '%s/databases/%s/pool.xml' "$ORDS_CONFIG" "$1"; }

# host port, for the connection types that have one.
pool_endpoint() {
    local f type url
    f="$(pool_file "$1")"
    type="$(config_value db.connectionType "$f")"
    case "${type:-basic}" in
        basic)
            printf '%s %s' "$(config_value db.hostname "$f")" "$(config_value db.port "$f" | grep . || echo 1521)" ;;
        customurl)
            url="$(config_value db.customURL "$f")"
            [[ $url =~ @(//)?([^:/()]+):([0-9]+) ]] && printf '%s %s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" ;;
    esac
}

pool_describe() {
    local f type
    f="$(pool_file "$1")"
    type="$(config_value db.connectionType "$f")"
    case "${type:-basic}" in
        basic)     printf '%s:%s/%s' "$(config_value db.hostname "$f")" "$(config_value db.port "$f" | grep . || echo 1521)" \
                       "$(config_value db.servicename "$f" | grep . || config_value db.sid "$f")" ;;
        tns)       printf 'TNS alias %s' "$(config_value db.tnsAliasName "$f")" ;;
        customurl) printf '%s' "$(config_value db.customURL "$f")" ;;
        *)         printf '%s' "$type" ;;
    esac
    printf ' as %s' "$(config_value db.username "$f" | grep . || echo ORDS_PUBLIC_USER)"
}

# The last N log lines that are not Java stack frames.
log_tail() {
    journalctl -u "$ORDS_SERVICE" -n 200 -o cat --no-pager -q 2>/dev/null \
        | grep -vE '^[[:space:]]+at |^[[:space:]]*\.\.\. [0-9]+ more' | tail -n "$1"
}

http_code() {
    curl -ks -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null || true
}

# =============================================================================
#  Checks
# =============================================================================
section "Settings"
if [ -f "$CONF" ]; then
    check settings.file INFO "Using ${CONF}"
    if [ -n "$(sed -n 's/^ORDS_ADMIN_PWD=\(.\)/\1/p' "$CONF")" ] && [ "$(( 8#$(stat -c %a "$CONF") & 8#077 ))" -ne 0 ]; then
        check settings.permissions WARN "${CONF} holds a password and other users can read it" "chmod 600 ${CONF}"
    fi
else
    check settings.file INFO "No ${CONF}; using defaults and what the systemd unit says"
fi

# --- Detection ---------------------------------------------------------------
section "Install"
if ! detect_err="$( (detect) 2>&1 >/dev/null )"; then
    check install.detect FAIL "Could not work out how ORDS is installed" "$(clean "$detect_err")"
    if systemctl cat "$ORDS_SERVICE" >/dev/null 2>&1; then
        check service.state INFO "$(systemctl is-active "$ORDS_SERVICE" 2>/dev/null)" \
            "$(log_tail 12)"
    fi
    finish
fi
detect
make_probe_dir
check install.detect PASS "Found ORDS through unit ${ORDS_SERVICE}"

fact service "$ORDS_SERVICE"
fact layout "$LAYOUT"
fact ords_home "$ORDS_HOME"
[ "$ORDS_REAL" = "$ORDS_HOME" ] || fact ords_home_target "$ORDS_REAL"
fact ords_config "$ORDS_CONFIG"
fact ords_user "$ORDS_USER"
fact pools "${POOLS[*]:-(none)}"
fact log_source "${ORDS_LOG_FILE:-journal}"
fact origin "$(ords_origin)$(ords_context)/"

version_out="$(ords_version_output "$ORDS_HOME")"
INSTALLED_BUILD="$(printf '%s' "$version_out" | grep -oE 'Oracle REST Data Services [0-9]+\.[0-9]+\.[0-9]+\.r[0-9]+' | awk '{print $NF}' | sed -n 1p)"
if grep -q UnsupportedClassVersionError <<<"$version_out"; then
    check install.version FAIL "The installed ORDS needs Java $(java_needed_from "$version_out") or later; the service's Java is older"
elif [ -z "$INSTALLED_BUILD" ]; then
    check install.version FAIL "${ORDS_HOME}/bin/ords --version did not print a version" "$(printf '%s' "$version_out" | tail -8)"
else
    fact installed_build "$INSTALLED_BUILD"
    check install.version PASS "ORDS ${INSTALLED_BUILD} is installed"
fi
[ "$LAYOUT" != rpm ] || fact rpm_version "$(rpm -q --qf '%{VERSION}-%{RELEASE}' ords)"

# The Java the service uses, as the service user sees it.
java_bin="${ORDS_JAVA_HOME:+${ORDS_JAVA_HOME}/bin/java}"
java_bin="${java_bin:-$(runuser -u "$ORDS_USER" -- bash -lc 'command -v java' 2>/dev/null)}"
if [ -n "$java_bin" ] && [ -x "$java_bin" ]; then
    java_line="$(runuser -u "$ORDS_USER" -- "$java_bin" -version 2>&1 | sed -n 1p)"
    java_major="$(printf '%s' "$java_line" | sed -n 's/.*version "\([0-9]*\)\.\{0,1\}\([0-9]*\).*/\1 \2/p' | awk '{print ($1 == 1) ? $2 : $1}')"
    fact java "${java_bin} (${java_line})"
    check install.java PASS "Java ${java_major:-?} at ${java_bin}" \
        "Whether the NEXT release runs on it is checked by ords-upgrade.sh --dry-run, before anything changes."
else
    check install.java FAIL "No Java found for ${ORDS_USER} - set JAVA_HOME in the unit or ORDS_JAVA_HOME"
fi

if runuser -u "$ORDS_USER" -- test -r "${ORDS_REAL}/ords.war"; then
    check install.readable PASS "${ORDS_USER} can read ${ORDS_REAL}/ords.war"
else
    check install.readable FAIL "${ORDS_USER} cannot read ${ORDS_REAL}/ords.war" "Check ownership and permissions of ${ORDS_REAL}."
fi

case "$LAYOUT" in
    symlink)
        kept="$(find "$ORDS_VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort -V | tr '\n' ' ')"
        check install.versions INFO "Releases kept in ${ORDS_VERSIONS_DIR}: ${kept:-(none)}" ;;
    plain)
        check install.layout INFO "Plain install: the first upgrade moves ${ORDS_HOME} into ${ORDS_VERSIONS_DIR} and puts a symlink in its place" ;;
    rpm)
        check install.layout INFO "RPM install: the upgrade uses dnf, and rollback uses dnf downgrade" ;;
esac

if blockers="$( (check_nothing_lives_in_home) 2>&1 )"; then
    check install.upgrade_blockers PASS "Nothing the upgrade depends on lives inside ${ORDS_HOME}"
else
    check install.upgrade_blockers FAIL "ords-upgrade.sh will refuse to run on this layout" "$(clean "$blockers")"
fi

# --- Service -----------------------------------------------------------------
section "Service"
state="$(unit_prop ActiveState)"; substate="$(unit_prop SubState)"
case "$state" in
    active)
        check service.state PASS "${ORDS_SERVICE} is running (since $(unit_prop ActiveEnterTimestamp))" ;;
    activating|reloading)
        check service.state WARN "${ORDS_SERVICE} is ${state} (${substate}) - still starting, or restarting in a loop" ;;
    *)
        check service.state FAIL "${ORDS_SERVICE} is ${state:-unknown} (${substate}, result: $(unit_prop Result))" \
            "The upgrade leaves a stopped service stopped and cannot health-check it. Last log lines:
$(log_tail 12)" ;;
esac

restarts="$(unit_prop NRestarts)"
if [ "${restarts:-0}" -gt 0 ] 2>/dev/null; then
    check service.restarts WARN "systemd has restarted ${ORDS_SERVICE} ${restarts} time(s) - it has been crashing"
fi

if [ "$(unit_prop UnitFileState)" = enabled ]; then
    check service.enabled PASS "Starts at boot"
else
    check service.enabled WARN "Not enabled: ${ORDS_SERVICE} will not start after a reboot" "systemctl enable ${ORDS_SERVICE}"
fi

port="$(ords_origin | sed 's/.*://')"
if command -v ss >/dev/null 2>&1; then
    listener="$(ss -ltnpH "sport = :${port}" 2>/dev/null | sed -n 1p)"
    lpid="$(printf '%s' "$listener" | grep -oE 'pid=[0-9]+' | sed -n 1p | cut -d= -f2)"
    if [ -z "$listener" ]; then
        if [ "$state" = active ]; then
            check service.port FAIL "Nothing is listening on port ${port}, although ${ORDS_SERVICE} is running"
        fi
    else
        luser="$(ps -o user= -p "$lpid" 2>/dev/null | tr -d ' ')"
        lcmd="$(ps -o comm= -p "$lpid" 2>/dev/null)"
        if [ "$luser" = "$ORDS_USER" ]; then
            check service.port PASS "Port ${port} is held by ${lcmd} (pid ${lpid}, user ${luser})"
        else
            check service.port WARN "Port ${port} is held by ${lcmd:-?} (pid ${lpid:-?}, user ${luser:-?}), not by ${ORDS_USER}" \
                "Another process may own the port, so ORDS cannot bind it after a restart."
        fi
    fi
fi

# --- Configuration -----------------------------------------------------------
section "Configuration"
unreadable="$(runuser -u "$ORDS_USER" -- find "$ORDS_CONFIG" ! -readable 2>/dev/null | sed -n 1,10p)"
foreign="$(find "$ORDS_CONFIG" ! -user "$ORDS_USER" 2>/dev/null | sed -n 1,10p)"
if [ -n "$unreadable" ]; then
    check config.ownership FAIL "${ORDS_USER} cannot read parts of ${ORDS_CONFIG}" \
        "Usually from running 'ords' as root. Fix: chown -R ${ORDS_USER} ${ORDS_CONFIG}
${unreadable}"
elif [ -n "$foreign" ]; then
    check config.ownership WARN "Some of ${ORDS_CONFIG} is not owned by ${ORDS_USER}" "$foreign"
else
    check config.ownership PASS "${ORDS_CONFIG} is owned by ${ORDS_USER}"
fi

leftovers="$(find "$(dirname "$ORDS_CONFIG")" -maxdepth 1 \( -name "$(basename "$ORDS_CONFIG").replaced-*" -o -name "$(basename "$ORDS_CONFIG").failed-*" \) 2>/dev/null)"
[ -z "$leftovers" ] || check config.set_aside INFO "Configs set aside by earlier upgrades or rollbacks; delete them when no longer needed" "$leftovers"

[ "${#POOLS[@]}" -gt 0 ] || check config.pools WARN "No pools in ${ORDS_CONFIG}/databases - ORDS serves no database"
for pool in "${POOLS[@]}"; do
    check "pool.${pool}.config" INFO "$(pool_describe "$pool")"
    if [ -f "${ORDS_CONFIG}/databases/${pool}/wallet/cwallet.sso" ]; then
        check "pool.${pool}.wallet" PASS "Wallet present"
    else
        check "pool.${pool}.wallet" WARN "No wallet/cwallet.sso - the pool has no stored password"
    fi

    read -r host dbport <<<"$(pool_endpoint "$pool")"
    if [ -z "${host:-}" ]; then
        check "pool.${pool}.network" INFO "Connection type has no single host to test"
    elif ! getent hosts "$host" >/dev/null 2>&1; then
        check "pool.${pool}.network" FAIL "${host} does not resolve from this server"
    elif timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${dbport}" 2>/dev/null; then
        check "pool.${pool}.network" PASS "${host}:${dbport} accepts connections"
    else
        check "pool.${pool}.network" FAIL "${host}:${dbport} does not accept connections from this server" \
            "On RDS, check the instance's security group allows this server on port ${dbport}."
    fi
done

# --- Last start --------------------------------------------------------------
section "Last start"
START_LOG="$(last_start_log)"
table="$(printf '%s\n' "$START_LOG" | pool_table)"
if grep -q 'REST Data Services initialized' <<<"$START_LOG"; then
    check log.initialized PASS "ORDS finished starting and logged its pool table"
elif [ "$state" = active ]; then
    check log.initialized WARN "No 'initialized' line in the log of this start" \
        "ORDS may still be starting, or logs somewhere this script is not reading - set ORDS_LOG_FILE.
The upgrade waits for this line to judge the new version, so it would roll back."
fi

RUNNING_BUILD="$(printf '%s' "$START_LOG" | sed -n 's/.*REST Data Services version : *\([^ ]*\).*/\1/p' | tail -1)"
if [ -n "$RUNNING_BUILD" ]; then
    fact running_build "$RUNNING_BUILD"
    if [ -n "$INSTALLED_BUILD" ] && [ "$RUNNING_BUILD" != "$INSTALLED_BUILD" ]; then
        check log.running_version WARN "Running ${RUNNING_BUILD}, but the files on disk are ${INSTALLED_BUILD}" \
            "The files changed since ORDS started. A restart would switch to ${INSTALLED_BUILD}."
    fi
fi

for pool in "${POOLS[@]}"; do
    line="$(printf '%s\n' "$table" | grep -E "=> *${pool} *=>" | tail -1)"
    if [ -z "$line" ]; then
        [ -z "$table" ] || check "pool.${pool}.status" WARN "Not in the pool table of the last start"
        continue
    fi
    pstatus="$(printf '%s' "$line" | awk '{print $NF}')"
    if [ "$pstatus" = VALID ]; then
        check "pool.${pool}.status" PASS "VALID at the last start"
    else
        pool_lines="$(printf '%s\n' "$START_LOG" | grep -F "|${pool}|")"
        reason="$(printf '%s\n' "$pool_lines" | grep -iE 'invalid|unable' | sed -n 1p \
                  | sed 's/.*will be ignored: //; s/.*Exception: //; s/ The connection pool named.*//' | cut -c1-300)"
        # The ORA- code is on the pool's own line in newer releases, and on a
        # separate "Caused by" line in older ones; with one pool it is unambiguous.
        ora="$(printf '%s\n' "$pool_lines" | grep -oE 'ORA-[0-9]{5}' | sed -n 1p)"
        [ -n "$ora" ] || [ "${#POOLS[@]}" -ne 1 ] || ora="$(printf '%s\n' "$START_LOG" | grep -oE 'ORA-[0-9]{5}' | sed -n 1p)"
        hint="$(ora_hint "${ora:-$reason}")"
        # Only a running ORDS makes this current; after a stop it is history,
        # and the cause may already have been fixed.
        if [ "$state" = active ]; then
            pool_status=FAIL; pool_summary="${pstatus} at the last start: ORDS cannot use this database"
        else
            pool_status=WARN; pool_summary="${pstatus} when ORDS last started - it is not running now, so this may be out of date"
        fi
        check "pool.${pool}.status" "$pool_status" "$pool_summary" \
            "${reason}${ora:+ (${ora})}${hint:+
Hint: ${hint}}
ords-upgrade.sh rolls back if any pool is not VALID after the new version starts, so an upgrade fails until this is fixed."
    fi
done

# INFO lines are ORDS's request log (including this script's own requests),
# and the exception dumps repeat the pool failure already reported above.
errors="$(printf '%s\n' "$START_LOG" | grep -E 'SEVERE|ORA-[0-9]{5}' \
          | grep -vE 'will be ignored|^[0-9TZ:.-]+ +INFO |DatabaseCredentialException \[|^Caused by: oracle\.dbtools' \
          | sed -E 's/^[0-9TZ:.-]+ +//; s/<[A-Za-z0-9_-]{20,}>//' | cut -c1-200 | sort | uniq -c | sort -rn | head -8)"
if [ -n "$errors" ]; then
    check log.errors WARN "Errors logged since the last start (count, message)" "$errors"
elif [ -n "$START_LOG" ]; then
    check log.errors PASS "No SEVERE or ORA- errors since the last start"
fi

# --- HTTP --------------------------------------------------------------------
if [ "$state" = active ]; then
    section "HTTP"
    origin="$(ords_origin)"
    code="$(http_code "$(default_health_urls)")"
    case "$code" in
        2??|3??) check http.base PASS "$(default_health_urls) answers HTTP ${code}" ;;
        *)       check http.base FAIL "$(default_health_urls) answers HTTP ${code:-nothing}" ;;
    esac

    COOKIES="$(mktemp)"
    while read -r path _ pname _ _; do
        [ -n "${path:-}" ] || continue
        f="$(pool_file "$pname")"
        gateway="$(config_value plsql.gateway.mode "$f")"
        gateway="${gateway:-$(settings_value plsql.gateway.mode)}"
        # A request that needs the database: 57x means ORDS could not use it.
        code="$(http_code -L --max-redirs 5 -c "$COOKIES" -b "$COOKIES" "${origin}${path}_/landing")"
        case "$code" in
            2??|3??) check "http.${pname}.database" PASS "${path}_/landing answers HTTP ${code}" ;;
            57?)     check "http.${pname}.database" FAIL "${path}_/landing answers HTTP ${code}: ORDS cannot use this pool's database" ;;
            *)       check "http.${pname}.database" INFO "${path}_/landing answers HTTP ${code} (Database Actions may be off; not a database test)" ;;
        esac
        case "$gateway" in
            proxied|direct)
                code="$(http_code -L --max-redirs 5 -c "$COOKIES" -b "$COOKIES" "${origin}${path}apex")"
                case "$code" in
                    2??) check "http.${pname}.apex" PASS "${path}apex (APEX) answers HTTP ${code}" ;;
                    *)   check "http.${pname}.apex" FAIL "${path}apex (APEX) answers HTTP ${code:-nothing}" ;;
                esac ;;
        esac
    done <<<"$(printf '%s\n' "$table" | sed 's/^ *//')"

    for url in $HEALTH_URLS; do
        code="$(http_code "$url")"
        case "$code" in
            2??|3??) check http.health_url PASS "${url} answers HTTP ${code}" ;;
            *)       check http.health_url FAIL "${url} answers HTTP ${code:-nothing}" \
                         "HEALTH_URLS in ${CONF}: the upgrade needs this to answer 2xx/3xx, or it rolls back." ;;
        esac
    done
fi

# --- Disk --------------------------------------------------------------------
section "Disk"
release_mb="$(du -sm "$ORDS_REAL" 2>/dev/null | awk '{print $1}')"
# The next release is usually bigger than this one (24.4 unpacks to ~150 MB,
# 26.2's zip alone is ~200 MB), so allow double, and never less than 500 MB.
release_mb="${release_mb:-250}"
release_mb=$(( release_mb * 2 > 500 ? release_mb * 2 : 500 ))
if [ "$LAYOUT" = rpm ]; then
    targets=("$ORDS_REAL:$release_mb")
else
    # The new release is unpacked in /var/tmp, then moved next to the old one.
    targets=("$ORDS_VERSIONS_DIR:$release_mb" "/var/tmp:$release_mb" "$BACKUP_DIR:250")
fi
for t in "${targets[@]}"; do
    dir="${t%:*}"; need="${t##*:}"
    free="$(free_mb "$dir")"
    if [ -z "$free" ]; then
        check disk.space INFO "Could not read free space for ${dir}"
    elif [ "$free" -lt "$need" ]; then
        check disk.space FAIL "${dir}: ${free} MB free, the upgrade needs about ${need} MB"
    else
        check disk.space PASS "${dir}: ${free} MB free (needs about ${need} MB)"
    fi
done

# --- Upgrade readiness -------------------------------------------------------
section "Upgrade readiness"
missing=""
tools=(curl unzip tar flock runuser)
[ "$LAYOUT" != rpm ] || tools+=(dnf)
for tool in "${tools[@]}"; do command -v "$tool" >/dev/null 2>&1 || missing+="${tool} "; done
if [ -n "$missing" ]; then
    check upgrade.tools FAIL "Missing commands the upgrade needs: ${missing}"
else
    check upgrade.tools PASS "The commands the upgrade needs are installed"
fi

if [ "$LAYOUT" = rpm ]; then
    # -C: dnf's cache only, so this check changes nothing.
    latest="$(dnf -q -C repoquery --latest-limit=1 --qf '%{version}-%{release}\n' ords 2>/dev/null | grep . | tail -1)"
    if [ -n "$latest" ]; then
        fact rpm_latest_cached "$latest"
        check upgrade.source INFO "dnf's cache offers ords-${latest} (installed: $(rpm -q --qf '%{VERSION}-%{RELEASE}' ords))"
    else
        check upgrade.source INFO "Nothing about ords in dnf's cache; ords-upgrade.sh --dry-run asks the repositories"
    fi
elif [ "$OFFLINE" = false ]; then
    if curl -fsIL --max-time 20 --retry 1 -o /dev/null "${ORDS_DOWNLOAD_BASE}/ords-latest.zip" 2>/dev/null; then
        check upgrade.source PASS "Oracle's download site is reachable"
    else
        check upgrade.source WARN "Cannot reach ${ORDS_DOWNLOAD_BASE}/ords-latest.zip" \
            "Download the zip elsewhere and run ords-upgrade.sh --zip FILE."
    fi
fi

if [ "${#POOLS[@]}" -gt 0 ]; then
    if [ -n "${ORDS_ADMIN_PWD:-}" ]; then
        check upgrade.admin_password PASS "ORDS_ADMIN_PWD is set in the environment"
    elif [ -n "$ORDS_ADMIN_PWD_FILE" ]; then
        if [ ! -r "$ORDS_ADMIN_PWD_FILE" ]; then
            check upgrade.admin_password FAIL "ORDS_ADMIN_PWD_FILE ${ORDS_ADMIN_PWD_FILE} does not exist or cannot be read"
        elif [ -z "$(head -n1 "$ORDS_ADMIN_PWD_FILE")" ]; then
            check upgrade.admin_password FAIL "${ORDS_ADMIN_PWD_FILE} is empty"
        elif [ "$(( 8#$(stat -c %a "$ORDS_ADMIN_PWD_FILE") & 8#077 ))" -ne 0 ]; then
            check upgrade.admin_password WARN "${ORDS_ADMIN_PWD_FILE} can be read by other users" "chmod 600 ${ORDS_ADMIN_PWD_FILE}"
        else
            check upgrade.admin_password PASS "Password file ${ORDS_ADMIN_PWD_FILE} is in place (not tested against the database)"
        fi
    else
        check upgrade.admin_password WARN "No ORDS_ADMIN_PWD_FILE: the upgrade will prompt, so it must run in a terminal"
    fi
    check upgrade.admin_user INFO "The schema upgrade logs in as ${ORDS_ADMIN_USER}$([ -f "$CONF" ] || echo ' (the default - set ORDS_ADMIN_USER)')"
fi

if [ -z "$RDS_INSTANCE_ID" ]; then
    check upgrade.db_snapshot WARN "RDS_INSTANCE_ID is not set: no snapshot will be taken" \
        "The ORDS schema upgrade cannot be undone without one."
elif ! command -v aws >/dev/null 2>&1; then
    check upgrade.db_snapshot FAIL "RDS_INSTANCE_ID is set but the aws CLI is not installed; the upgrade will stop"
elif [ "$OFFLINE" = true ]; then
    check upgrade.db_snapshot INFO "RDS_INSTANCE_ID=${RDS_INSTANCE_ID}; not checked (--offline)"
else
    if ! rds="$(timeout 30 aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
                --query 'DBInstances[0].[DBInstanceStatus,Engine,Endpoint.Address]' --output text 2>&1)"; then
        check upgrade.db_snapshot FAIL "aws cannot describe RDS instance ${RDS_INSTANCE_ID}" "$rds"
    else
        read -r rds_status rds_engine rds_host <<<"$rds"
        fact rds_endpoint "${rds_host:-}"
        pool_hosts=""
        for pool in "${POOLS[@]}"; do pool_hosts+="$(pool_endpoint "$pool" | awk '{print $1}')"$'\n'; done
        if [ "$rds_status" != available ]; then
            check upgrade.db_snapshot WARN "RDS instance ${RDS_INSTANCE_ID} is '${rds_status}'; a snapshot needs it 'available'"
        elif [ -n "$rds_host" ] && ! grep -qixF "$rds_host" <<<"$pool_hosts"; then
            check upgrade.db_snapshot WARN "RDS instance ${RDS_INSTANCE_ID} (${rds_host}) is not the host any pool uses" \
                "Pools use: $(printf '%s' "$pool_hosts" | grep . | sort -u | tr '\n' ' ')- a snapshot of the wrong instance protects nothing.
Expected if the pools reach RDS through a DNS alias rather than the endpoint name."
        else
            check upgrade.db_snapshot PASS "RDS instance ${RDS_INSTANCE_ID} (${rds_engine}) is available and matches a pool; aws can describe it"
        fi
    fi
fi

# What earlier runs left behind.
if [ -f "${BACKUP_DIR}/.lock" ] && ! flock -n "${BACKUP_DIR}/.lock" true 2>/dev/null; then
    check upgrade.running FAIL "ords-upgrade.sh is running right now (it holds ${BACKUP_DIR}/.lock)"
fi
latest_run="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '2*' 2>/dev/null | sort | tail -1)"
if [ -n "$latest_run" ] && [ -f "${latest_run}/state" ]; then
    run_status="$(sed -n 's/^STATUS=//p' "${latest_run}/state" | tr -d "'")"
    run_from="$(sed -n 's/^OLD_VER=//p' "${latest_run}/state")"
    run_to="$(sed -n 's/^NEW_VER=//p' "${latest_run}/state")"
    run_snap="$(sed -n 's/^SNAP_ID=//p' "${latest_run}/state" | tr -d "'")"
    run_schema="$(sed -n 's/^SCHEMA_TOUCHED=//p' "${latest_run}/state")"
    if [ "$run_schema" = false ]; then
        schema_note="It failed before the schema step changed anything, so the database is as it was."
    else
        schema_note="The ORDS schema may already be on ${run_to}."
    fi
    fact last_run "$(basename "$latest_run"): ${run_from} -> ${run_to}, ${run_status}${run_snap:+, snapshot ${run_snap}}"
    case "$run_status" in
        done)
            check upgrade.last_run PASS "The last upgrade ($(basename "$latest_run"), ${run_from} -> ${run_to}) succeeded" ;;
        manually-rolled-back)
            check upgrade.last_run INFO "The last upgrade (${run_from} -> ${run_to}) was rolled back by hand; the ORDS schema stays on ${run_to}" ;;
        rolled-back)
            check upgrade.last_run WARN "The last upgrade (${run_from} -> ${run_to}) failed and rolled back" \
                "Read ${latest_run}/upgrade.log for the cause. ${schema_note}" ;;
        *)
            check upgrade.last_run FAIL "The last upgrade ($(basename "$latest_run")) stopped part-way: status '${run_status}'" \
                "Read ${latest_run}/upgrade.log before running again." ;;
    esac
fi

check upgrade.other_servers INFO "Other ORDS servers on the same database cannot be seen from here; upgrade them in the same window"

finish
