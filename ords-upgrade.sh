#!/usr/bin/env bash
# Upgrade ORDS on a server where it runs standalone under systemd. Run it on
# that server as root, from a copy of https://github.com/juliusbsimon/ords-tools
# (it needs ords-common.sh beside it).
#
#   ./ords-upgrade.sh                          # to the latest release
#   ./ords-upgrade.sh --dry-run                # show the plan; change nothing
#   ./ords-upgrade.sh --version 26.2.1.190.1402
#   ./ords-upgrade.sh --zip ords-26.2.1.zip    # server with no internet access
#   ./ords-upgrade.sh --rollback               # undo the last upgrade
#
# Options:
#   -c, --conf FILE   settings file (default /etc/ords-upgrade.conf)
#   --version V       a specific release instead of the latest. For zip
#                     installs, the build as 'ords --version' prints it
#                     (26.2.1.r1901402) or as the zip names it (26.2.1.190.1402).
#                     For RPM installs, the package version (26.2.3).
#   --zip FILE        install this zip instead of downloading one
#   --sha256 HEX      refuse a zip that does not match this checksum
#   -n, --dry-run     download and inspect the new release, print the plan, stop
#   -y, --yes         do not ask for confirmation
#   --force           reinstall the same version, or allow a downgrade
#   --rollback        put back the binaries and configuration from before the
#                     last upgrade. The database schema is NOT rolled back.
#
# Three layouts are handled, and the plan says which one was found:
#
#   symlink  ORDS_HOME is a symlink into a directory of unpacked zips. The new
#            release is unpacked beside the old one and the link is switched.
#   plain    ORDS_HOME is an unpacked zip. It is moved into the versions
#            directory and replaced by a symlink first, so it only happens once.
#   rpm      Installed from Oracle's yum repository. Upgraded with dnf.
#
# The database side is 'ords install', which upgrades the ORDS schema when it
# is already installed. It is the one step this script cannot undo, so set
# RDS_INSTANCE_ID and an RDS snapshot is taken before anything changes.
#
# Settings: see ords-upgrade.conf.example. Everything has a default or is read
# from the systemd unit.
set -euo pipefail

# shellcheck source=SCRIPTDIR/ords-common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ords-common.sh" \
    || { echo "ords-common.sh must be in the same directory as this script" >&2; exit 1; }

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# -----------------------------------------------------------------------------
#  Arguments and settings
# -----------------------------------------------------------------------------
CONF=/etc/ords-upgrade.conf
CONF_GIVEN=false
WANT_VERSION=latest
ZIP_FILE=""
ZIP_SHA256=""
DRY_RUN=false
ASSUME_YES=false
FORCE=false
ROLLBACK=false

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--conf)    CONF="${2:?--conf needs a file}"; CONF_GIVEN=true; shift 2 ;;
        --version)    WANT_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --zip)        ZIP_FILE="${2:?--zip needs a file}"; shift 2 ;;
        --sha256)     ZIP_SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -y|--yes)     ASSUME_YES=true; shift ;;
        --force)      FORCE=true; shift ;;
        --rollback)   ROLLBACK=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "Unknown option: $1 (see --help)" ;;
    esac
done

load_settings "$CONF" "$CONF_GIVEN"

[ "$(id -u)" -eq 0 ] || die "Run as root: it stops the service and replaces files owned by the ORDS user."
for tool in systemctl curl unzip tar flock runuser; do
    command -v "$tool" >/dev/null 2>&1 || die "Needs '${tool}', which is not installed."
done

# ORDS runs as its service user from a directory that user can read; root's
# home is not one, and a Java process started there fails on its own cwd.
cd /

# 711, not 700: the ORDS user writes its install logs under here and has to be
# able to get to them. It still cannot list the directory, and the config
# backups - which hold the pool wallets - are 600 on their own.
mkdir -p "$BACKUP_DIR"
chmod 711 "$BACKUP_DIR"
exec 9>"${BACKUP_DIR}/.lock"
flock -n 9 || die "Another ords-upgrade is already running (lock: ${BACKUP_DIR}/.lock)."

# -----------------------------------------------------------------------------
#  Small helpers
# -----------------------------------------------------------------------------
confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    [ -t 0 ] || die "Not running interactively; pass --yes to proceed without confirmation."
    local answer
    printf '    %s [y/N]: ' "$1"
    read -r answer
    case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) die "Stopped - nothing was changed." ;; esac
}

# -----------------------------------------------------------------------------
#  Getting the new release
# -----------------------------------------------------------------------------
STAGING=""
NEW_DIR=""

fetch_zip_release() {
    local zip name
    if [ -n "$ZIP_FILE" ]; then
        zip="$(readlink -f "$ZIP_FILE")"
        [ -f "$zip" ] || die "No such file: ${ZIP_FILE}"
    else
        if [ "$WANT_VERSION" = latest ]; then
            name=ords-latest.zip
        else
            name="$(zip_name_for "$WANT_VERSION")" || die "--version ${WANT_VERSION} is not a full build number.
     Use it as 'ords --version' prints it (26.2.1.r1901402) or as the zip is
     named (26.2.1.190.1402)."
        fi
        mkdir -p "${BACKUP_DIR}/downloads"
        zip="${BACKUP_DIR}/downloads/${name}"
        download "${ORDS_DOWNLOAD_BASE}/${name}" "$zip"
    fi

    if [ -n "$ZIP_SHA256" ]; then
        [ "$(sha256sum "$zip" | awk '{print $1}')" = "${ZIP_SHA256,,}" ] \
            || die "${zip} does not match --sha256."
        ok "Checksum matches"
    fi

    # Outside BACKUP_DIR, which the ORDS user cannot read, because the new
    # release is probed as that user.
    STAGING="$(mktemp -d /var/tmp/ords-upgrade.XXXXXX)"
    log "Unpacking"
    unzip -q "$zip" -d "${STAGING}/ords" || die "${zip} is not a usable zip."
    NEW_DIR="${STAGING}/ords"
    # Tolerate a zip that wraps everything in one top-level directory.
    if [ ! -f "${NEW_DIR}/bin/ords" ]; then
        local inner
        inner="$(find "$NEW_DIR" -mindepth 2 -maxdepth 3 -path '*/bin/ords' | sed -n 1p)"
        [ -n "$inner" ] || die "${zip} does not contain bin/ords - is it an ORDS zip?"
        NEW_DIR="$(dirname "$(dirname "$inner")")"
    fi
    chmod 755 "$STAGING"
    chown -R --reference="$ORDS_REAL" "$STAGING"

    NEW_VER="$(ords_version "$NEW_DIR")"
    [ -n "$NEW_VER" ] || die "Could not read a version from the new release."
}

rpm_version() { rpm -q --qf '%{VERSION}-%{RELEASE}' ords; }

fetch_rpm_release() {
    [ -z "$ZIP_FILE" ] || die "--zip does not apply: ORDS here is installed from an RPM."
    command -v dnf >/dev/null 2>&1 || die "ORDS is an RPM install but dnf is not available."
    local spec=ords
    [ "$WANT_VERSION" = latest ] || spec="ords-${WANT_VERSION}"
    log "Asking dnf for ${spec}"
    NEW_RPM="$(dnf -q repoquery --latest-limit=1 --qf '%{version}-%{release}\n' "$spec" 2>/dev/null | grep . | tail -1 || true)"
    [ -n "$NEW_RPM" ] || die "dnf found no package matching '${spec}'. Is Oracle's software repo
     enabled? (ol8_oracle_software / ol9_oracle_software)"
    NEW_VER="$NEW_RPM"
}

# -----------------------------------------------------------------------------
#  Safety nets
# -----------------------------------------------------------------------------
SNAP_ID=""
rds_snapshot() {
    [ -n "$RDS_INSTANCE_ID" ] || return 0
    command -v aws >/dev/null 2>&1 || die "RDS_INSTANCE_ID is set but the aws CLI is not installed."
    SNAP_ID="ords-upgrade-$(date +%Y%m%d-%H%M%S)"
    log "Taking RDS snapshot ${SNAP_ID} of ${RDS_INSTANCE_ID}"
    aws rds create-db-snapshot --db-instance-identifier "$RDS_INSTANCE_ID" \
        --db-snapshot-identifier "$SNAP_ID" >/dev/null \
        || die "Could not start the RDS snapshot. Nothing was changed."
    # Polled rather than 'aws rds wait', which gives up after 15 minutes - too
    # short for a large instance.
    local deadline=$((SECONDS + RDS_SNAPSHOT_TIMEOUT)) status
    while :; do
        status="$(aws rds describe-db-snapshots --db-snapshot-identifier "$SNAP_ID" \
                  --query 'DBSnapshots[0].Status' --output text 2>/dev/null || echo unknown)"
        case "$status" in
            available) break ;;
            failed|error|deleted) die "RDS snapshot ${SNAP_ID} ended as '${status}'. Nothing was changed." ;;
        esac
        [ "$SECONDS" -lt "$deadline" ] || die "RDS snapshot ${SNAP_ID} is still '${status}' after ${RDS_SNAPSHOT_TIMEOUT}s. Nothing was changed."
        printf '\r    snapshot %s (%ss)   ' "$status" "$SECONDS"
        sleep 30
    done
    printf '\r'
    ok "RDS snapshot ${SNAP_ID} is available"
}

backup_config() {
    CONFIG_BACKUP="${RUN_DIR}/config.tar.gz"
    ( umask 077; tar -C "$(dirname "$ORDS_CONFIG")" -czf "$CONFIG_BACKUP" "$(basename "$ORDS_CONFIG")" )
    ok "Configuration backed up to ${CONFIG_BACKUP}"
}

# The configuration being replaced is set aside rather than deleted: after a
# failure it is the evidence, and after --rollback it may hold wanted changes.
restore_config() {
    local aside
    aside="${ORDS_CONFIG}.replaced-$(date +%Y%m%d-%H%M%S)"
    mv "$ORDS_CONFIG" "$aside"
    tar -C "$(dirname "$ORDS_CONFIG")" -xzf "$CONFIG_BACKUP"
    ok "Configuration restored (the one it replaced is in ${aside})"
}

write_state() {
    local v
    for v in STATUS LAYOUT ORDS_SERVICE ORDS_HOME ORDS_CONFIG OLD_VER NEW_VER \
             OLD_DIR NEW_DIR_FINAL OLD_RPM NEW_RPM CONFIG_BACKUP SNAP_ID WAS_ACTIVE \
             SCHEMA_TOUCHED; do
        printf '%s=%q\n' "$v" "${!v:-}"
    done >"${RUN_DIR}/state"
}

# -----------------------------------------------------------------------------
#  Service
# -----------------------------------------------------------------------------
start_and_check() {
    [ "$WAS_ACTIVE" = true ] || { warn "${ORDS_SERVICE} was stopped before the upgrade, so it is left stopped and not health-checked."; return 0; }
    STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
    LOG_OFFSET="$(stat -c %s "$ORDS_LOG_FILE" 2>/dev/null || echo 0)"
    systemctl start "$ORDS_SERVICE"
    healthy
}

# Anything else ORDS complained about while starting. Informational: plenty of
# healthy installs log a SEVERE or two, so this does not fail the upgrade.
report_log_errors() {
    [ -n "${STARTED_AT:-}" ] || return 0
    local errors
    errors="$(startup_log \
              | grep -E 'SEVERE|ERROR|ORA-[0-9]+' | sed -n 1,15p || true)"
    [ -z "$errors" ] && return 0
    warn "ORDS logged errors since it started - worth a look:"
    printf '%s\n' "$errors" | sed 's/^/       /' >&2
}

# -----------------------------------------------------------------------------
#  Switching binaries
# -----------------------------------------------------------------------------
point_home_at() {
    ln -sfn "$1" "${ORDS_HOME}.new-link"
    mv -Tf "${ORDS_HOME}.new-link" "$ORDS_HOME"
}

install_binaries() {
    case "$LAYOUT" in
        plain)
            mkdir -p "$ORDS_VERSIONS_DIR"
            OLD_DIR="${ORDS_VERSIONS_DIR}/${OLD_VER}"
            [ ! -e "$OLD_DIR" ] || die "${OLD_DIR} already exists; move it aside and rerun."
            log "Moving ${ORDS_HOME} to ${OLD_DIR} and replacing it with a symlink (once only)"
            mv "$ORDS_HOME" "$OLD_DIR"
            point_home_at "$OLD_DIR"
            LAYOUT=symlink
            ;;
        symlink)
            mkdir -p "$ORDS_VERSIONS_DIR"
            OLD_DIR="$ORDS_REAL"
            ;;
        rpm)
            log "dnf install ords-${NEW_RPM}"
            dnf -y -q install "ords-${NEW_RPM}"
            # The package's scriptlets may start the service; the schema is
            # upgraded with ORDS stopped.
            systemctl stop "$ORDS_SERVICE" 2>/dev/null || true
            return 0
            ;;
    esac
    NEW_DIR_FINAL="${ORDS_VERSIONS_DIR}/${NEW_VER}"
    if [ -e "$NEW_DIR_FINAL" ]; then
        # Left by an earlier failed attempt; never the version in use, which
        # was ruled out before we got here unless --force.
        [ "$(readlink -f "$NEW_DIR_FINAL")" != "$OLD_DIR" ] || NEW_DIR_FINAL="${NEW_DIR_FINAL}-reinstall-$(date +%s)"
        rm -rf "$NEW_DIR_FINAL"
    fi
    mv "$NEW_DIR" "$NEW_DIR_FINAL"
    point_home_at "$NEW_DIR_FINAL"
    ok "${ORDS_HOME} -> ${NEW_DIR_FINAL}"
}

restore_binaries() {
    case "$LAYOUT" in
        symlink|plain)
            [ -n "${OLD_DIR:-}" ] && [ -d "$OLD_DIR" ] || { warn "Old release directory is gone; cannot switch back."; return 1; }
            point_home_at "$OLD_DIR"
            ok "${ORDS_HOME} -> ${OLD_DIR}"
            ;;
        rpm)
            log "dnf downgrade ords-${OLD_RPM}"
            dnf -y -q downgrade "ords-${OLD_RPM}" || { warn "dnf could not downgrade to ords-${OLD_RPM}."; return 1; }
            systemctl stop "$ORDS_SERVICE" 2>/dev/null || true
            ;;
    esac
}

# -----------------------------------------------------------------------------
#  Database
# -----------------------------------------------------------------------------
read_admin_password() {
    if [ -n "${ORDS_ADMIN_PWD:-}" ]; then
        ADMIN_PWD="$ORDS_ADMIN_PWD"
    elif [ -n "$ORDS_ADMIN_PWD_FILE" ]; then
        [ -r "$ORDS_ADMIN_PWD_FILE" ] || die "Cannot read ORDS_ADMIN_PWD_FILE ${ORDS_ADMIN_PWD_FILE}"
        ADMIN_PWD="$(head -n1 "$ORDS_ADMIN_PWD_FILE")"
    elif [ -t 0 ]; then
        read -rsp "    Password for database user ${ORDS_ADMIN_USER}: " ADMIN_PWD
        echo
    else
        die "No password for ${ORDS_ADMIN_USER}. Set ORDS_ADMIN_PWD_FILE in ${CONF}."
    fi
    [ -n "$ADMIN_PWD" ] || die "The password for ${ORDS_ADMIN_USER} is empty."
}

upgrade_schema() {
    local pool admin_user="$ORDS_ADMIN_USER" logs="${RUN_DIR}/install-logs"
    # SYS on a self-managed database has to carry its role; RDS never has SYS.
    [ "${admin_user^^}" = SYS ] && admin_user="SYS AS SYSDBA"
    mkdir -p "$logs"
    chown "$ORDS_USER" "$logs"
    for pool in "${POOLS[@]}"; do
        log "Upgrading the ORDS schema through pool '${pool}'"
        local -a args=(--config "$ORDS_CONFIG" install --admin-user "$admin_user"
                       --log-folder "$logs" --password-stdin)
        # ORDS 26 rejects '--db-pool default' as a reserved name; leaving the
        # option out is how the default pool is addressed.
        [ "$pool" = default ] || args+=(--db-pool "$pool")
        SCHEMA_TOUCHED=true
        # A pipe rather than a here-string: bash before 5.1 backs here-strings
        # with a temp file, which would put the password on disk.
        if ! printf '%s\n' "$ADMIN_PWD" | run_ords "$ORDS_HOME" "${args[@]}" 2>&1 | tee "${logs}/${pool}.out"; then
            # Failing to log in is the common case, and it means the database
            # was never touched - worth saying, because the alternative
            # message is alarming.
            if grep -q 'Failed to connect to user' "${logs}/${pool}.out"; then
                [ "$pool" = "${POOLS[0]}" ] && SCHEMA_TOUCHED=false
                die "ORDS could not log in as ${ORDS_ADMIN_USER} through pool '${pool}'. Check the
     password and that the database is reachable from here."
            fi
            die "Schema upgrade through pool '${pool}' failed. Logs: ${logs}"
        fi
    done
    ok "ORDS schema upgraded"
}

# -----------------------------------------------------------------------------
#  Failure handling
# -----------------------------------------------------------------------------
CHANGED=false
ROLLING_BACK=false
SCHEMA_TOUCHED=false

auto_rollback() {
    ROLLING_BACK=true
    echo
    warn "The upgrade failed - putting ORDS ${OLD_VER} back."
    systemctl stop "$ORDS_SERVICE" 2>/dev/null || true
    restore_binaries || true
    restore_config || true
    STATUS=rolled-back
    write_state
    if [ "$WAS_ACTIVE" = true ]; then
        LOG_OFFSET="$(stat -c %s "$ORDS_LOG_FILE" 2>/dev/null || echo 0)"
        systemctl start "$ORDS_SERVICE" || true
        if healthy; then ok "ORDS ${OLD_VER} is serving again"; else warn "ORDS ${OLD_VER} is not healthy either - see journalctl -u ${ORDS_SERVICE}"; fi
    fi
    if [ "$SCHEMA_TOUCHED" = true ]; then
        warn "The ORDS schema upgrade had started, so the database may already be on"
        warn "${NEW_VER} while ORDS ${OLD_VER} runs against it. Fix the cause and rerun"
        warn "this script to finish the upgrade.$([ -n "$SNAP_ID" ] && printf ' RDS snapshot %s has the database as it was.' "$SNAP_ID")"
    fi
    warn "Log: ${RUN_DIR}/upgrade.log"
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$CHANGED" = true ] && [ "$ROLLING_BACK" = false ]; then
        auto_rollback || true
    fi
    [ -z "$STAGING" ] || rm -rf "$STAGING"
    [ -z "$PROBE_CFG" ] || rm -rf "$PROBE_CFG"
    exit "$rc"
}
trap on_exit EXIT

# -----------------------------------------------------------------------------
#  --rollback
# -----------------------------------------------------------------------------
manual_rollback() {
    local last="${BACKUP_DIR}/last"
    [ -f "${last}/state" ] || die "No upgrade recorded in ${BACKUP_DIR} to roll back."
    # detect() for how the service runs today; the state file for what the
    # upgrade replaced.
    detect
    make_probe_dir
    # shellcheck disable=SC1091
    . "${last}/state"
    if systemctl is-active --quiet "$ORDS_SERVICE"; then WAS_ACTIVE=true; else WAS_ACTIVE=false; fi
    HEALTH_URLS="${HEALTH_URLS:-$(default_health_urls)}"
    RUN_DIR="$(readlink -f "$last")"
    [ "$STATUS" = "done" ] || die "The last upgrade (${RUN_DIR}) is '${STATUS}', not 'done' - nothing to roll back."

    echo
    log "Roll back ORDS ${NEW_VER} -> ${OLD_VER}"
    echo "    binaries       $([ "$LAYOUT" = rpm ] && echo "dnf downgrade ords-${OLD_RPM}" || echo "${ORDS_HOME} -> ${OLD_DIR}")"
    echo "    configuration  restored from ${CONFIG_BACKUP}"
    echo "                   (configuration changes made since the upgrade are set aside)"
    echo "    database       NOT touched - the ORDS schema stays on ${NEW_VER}"
    [ -z "$SNAP_ID" ] || echo "                   RDS snapshot ${SNAP_ID} has it as it was before"
    echo
    confirm "Roll back?"

    exec > >(tee -a "${RUN_DIR}/rollback.log") 2>&1
    ROLLING_BACK=true
    systemctl stop "$ORDS_SERVICE" 2>/dev/null || true
    restore_binaries || die "Could not put the old binaries back."
    restore_config
    STATUS=manually-rolled-back
    write_state
    start_and_check || die "ORDS ${OLD_VER} is not healthy after the rollback - see journalctl -u ${ORDS_SERVICE}"
    ok "Rolled back to ORDS ${OLD_VER}"
}

# -----------------------------------------------------------------------------
#  Main
# -----------------------------------------------------------------------------
if [ "$ROLLBACK" = true ]; then
    manual_rollback
    exit 0
fi

detect
make_probe_dir
check_nothing_lives_in_home

if [ "$LAYOUT" = rpm ]; then
    OLD_RPM="$(rpm_version)"
    OLD_VER="$OLD_RPM"
    fetch_rpm_release
else
    OLD_VER="$(ords_version "$ORDS_HOME")"
    [ -n "$OLD_VER" ] || die "Could not read the installed ORDS version from ${ORDS_HOME}/bin/ords --version."
    fetch_zip_release
fi

if [ "$OLD_VER" = "$NEW_VER" ] && [ "$FORCE" = false ]; then
    ok "ORDS ${OLD_VER} is already installed. Nothing to do (--force reinstalls it)."
    exit 0
fi
if ver_lt "$NEW_VER" "$OLD_VER" && [ "$FORCE" = false ]; then
    die "${NEW_VER} is older than the installed ${OLD_VER}. ORDS schemas do not
     downgrade; --force only if you are sure."
fi

HEALTH_URLS="${HEALTH_URLS:-$(default_health_urls)}"

echo
log "ORDS upgrade plan"
printf '    %-12s %s\n' \
    "service"   "${ORDS_SERVICE} ($([ "$WAS_ACTIVE" = true ] && echo running || echo stopped))" \
    "layout"    "$LAYOUT" \
    "ORDS_HOME" "${ORDS_HOME}$([ "$LAYOUT" != symlink ] || printf ' -> %s' "$ORDS_REAL")" \
    "config"    "${ORDS_CONFIG}" \
    "pools"     "${POOLS[*]:-(none)}" \
    "runs as"   "${ORDS_USER}, Java: ${ORDS_JAVA_HOME:-from PATH}" \
    "installed" "$OLD_VER" \
    "upgrade to" "$NEW_VER" \
    "admin user" "$ORDS_ADMIN_USER" \
    "health"    "$HEALTH_URLS" \
    "db backup" "${RDS_INSTANCE_ID:+RDS snapshot of ${RDS_INSTANCE_ID}}${RDS_INSTANCE_ID:-NONE - set RDS_INSTANCE_ID; the schema upgrade cannot be undone without one}"
[ "$LAYOUT" != plain ] || printf '    %-12s %s\n' "note" "${ORDS_HOME} becomes a symlink into ${ORDS_VERSIONS_DIR}"
[ "${#POOLS[@]}" -gt 0 ] || warn "No pools in ${ORDS_CONFIG}/databases - only the binaries will change."
echo
echo "    Every other ORDS server using the same database should be upgraded in"
echo "    the same window: the schema moves forward for all of them at once."
echo

if [ "$DRY_RUN" = true ]; then
    ok "Dry run - nothing changed."
    exit 0
fi

[ "${#POOLS[@]}" -eq 0 ] || read_admin_password
confirm "Upgrade ORDS ${OLD_VER} -> ${NEW_VER}$([ -n "$RDS_INSTANCE_ID" ] || echo ' WITHOUT a database snapshot')?"

RUN_DIR="${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
chmod 711 "$RUN_DIR"
exec > >(tee -a "${RUN_DIR}/upgrade.log") 2>&1
STATUS=started
write_state

rds_snapshot
backup_config

log "Stopping ${ORDS_SERVICE}"
systemctl stop "$ORDS_SERVICE"
CHANGED=true

install_binaries
write_state
[ "${#POOLS[@]}" -eq 0 ] || upgrade_schema

if [ "$LAYOUT" = rpm ]; then INSTALLED_NOW="$(rpm_version)"; else INSTALLED_NOW="$(ords_version "$ORDS_HOME")"; fi
[ "$INSTALLED_NOW" = "$NEW_VER" ] || die "Expected ${NEW_VER} after the switch but found '${INSTALLED_NOW}'."

log "Starting ${ORDS_SERVICE}"
start_and_check || die "ORDS ${NEW_VER} did not come up healthy."
report_log_errors

CHANGED=false
STATUS="done"
write_state
ln -sfn "$RUN_DIR" "${BACKUP_DIR}/last"

# Keep the release just replaced (for --rollback) plus the newest others, up
# to KEEP_VERSIONS in total.
if [ "$LAYOUT" != rpm ] && [ -d "$ORDS_VERSIONS_DIR" ]; then
    keep=$(( KEEP_VERSIONS > 2 ? KEEP_VERSIONS - 2 : 0 ))
    find "$ORDS_VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2- \
        | grep -vxF -e "$NEW_DIR_FINAL" -e "$OLD_DIR" \
        | tail -n +$((keep + 1)) \
        | while read -r old; do log "Removing old release ${old}"; rm -rf "$old"; done \
        || true
fi

echo
ok "ORDS upgraded: ${OLD_VER} -> ${NEW_VER}"
log "Undo with: $0 --rollback    (binaries and config; the schema stays on ${NEW_VER})"
log "Record of this run: ${RUN_DIR}"
