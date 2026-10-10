#!/usr/bin/env bash
# Install ORDS on a new server, in the layout ords-upgrade.sh and ords-diag.sh
# expect, so upgrades work from the first day:
#
#   /opt/ords-versions/<build>   the unpacked release, owned by root
#   /opt/ords                    symlink to it - what the service runs
#   /etc/ords/config             the configuration, owned by the service user
#   ords.service                 systemd, as the 'ords' system user, Java 21 from dnf
#
#   ./ords-install.sh --db-host mydb.abc123.us-east-2.rds.amazonaws.com --db-service ORCL --dry-run
#   ./ords-install.sh --db-host mydb.abc123.us-east-2.rds.amazonaws.com --db-service ORCL
#
# Works for the first ORDS server on a database (installs the ORDS schema) and
# for later ones (joins the schema that is there). Run it as root.
#
# Options:
#   --db-host HOST         database host (required)
#   --db-port N            listener port (default 1521)
#   --db-service NAME      database service name (required)
#   --admin-user USER      installs or checks the ORDS schema: the RDS master
#                          user, or SYS on a self-managed database (default admin)
#   --admin-pwd-file FILE  that user's password, on the first line. Prompted for
#                          when not given
#   --proxy-pwd-file FILE  the ORDS_PUBLIC_USER password. Required when ORDS is
#                          already in the database: this server connects as that
#                          user, with the password the other servers use. It is
#                          tested before anything is installed. On a database
#                          without ORDS, one is generated and saved to
#                          /root/.ords-public-user-pwd
#   --new-proxy-password   when joining, set the password in --proxy-pwd-file as
#                          ORDS_PUBLIC_USER's new password in the database. The
#                          other servers' pools stop working until each is given
#                          it; the plan shows the command for that
#   --port N               HTTP port for ORDS (default 8080)
#   --version V            a specific ORDS build, e.g. 26.3.0.r2721811; default latest
#   --zip FILE             install this ORDS zip instead of downloading one
#   --sha256 HEX           refuse a zip that does not match this checksum
#   --no-apex              no PL/SQL gateway: ORDS for REST services only
#   --apex-cdn             point APEX at Oracle's CDN even when ORDS is already in
#                          the database. Done anyway on a database whose APEX
#                          still uses the default /i/ and has no ORDS yet
#   --database-actions     turn on Database Actions (SQL Developer Web), with the
#                          REST-enabled SQL and Database API it needs. All three
#                          are off by default
#   --java-home DIR        use this Java instead of installing java-21-openjdk-headless
#   --service-user NAME    default ords
#   -n, --dry-run          check everything and print the plan; install nothing
#                          (Java must already be installed to check the database)
#   -y, --yes              do not ask for confirmation
#
# Needs ords-common.sh and ords-db.java beside it; all come from
# https://github.com/juliusbsimon/ords-tools.
set -euo pipefail

# shellcheck source=SCRIPTDIR/ords-common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ords-common.sh" \
    || { echo "ords-common.sh must be in the same directory as this script" >&2; exit 1; }
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# -----------------------------------------------------------------------------
#  Arguments
# -----------------------------------------------------------------------------
DB_HOST=""; DB_PORT=1521; DB_SERVICE=""
ADMIN_USER="admin"; ADMIN_PWD_FILE=""; PROXY_PWD_FILE=""; NEW_PROXY=false
PORT=8080; WANT_VERSION=latest; ZIP_FILE=""; ZIP_SHA256=""
APEX=true; APEX_CDN=false; DB_ACTIONS=false
JAVA_HOME_OPT=""; SVC_USER=ords; DRY_RUN=false; ASSUME_YES=false

while [ $# -gt 0 ]; do
    case "$1" in
        --db-host)            DB_HOST="${2:?--db-host needs a value}"; shift 2 ;;
        --db-port)            DB_PORT="${2:?--db-port needs a value}"; shift 2 ;;
        --db-service)         DB_SERVICE="${2:?--db-service needs a value}"; shift 2 ;;
        --admin-user)         ADMIN_USER="${2:?--admin-user needs a value}"; shift 2 ;;
        --admin-pwd-file)     ADMIN_PWD_FILE="${2:?--admin-pwd-file needs a file}"; shift 2 ;;
        --proxy-pwd-file)     PROXY_PWD_FILE="${2:?--proxy-pwd-file needs a file}"; shift 2 ;;
        --new-proxy-password) NEW_PROXY=true; shift ;;
        --port)               PORT="${2:?--port needs a value}"; shift 2 ;;
        --version)            WANT_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --zip)                ZIP_FILE="${2:?--zip needs a file}"; shift 2 ;;
        --sha256)             ZIP_SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
        --no-apex)            APEX=false; shift ;;
        --apex-cdn)           APEX_CDN=true; shift ;;
        --database-actions)   DB_ACTIONS=true; shift ;;
        --java-home)          JAVA_HOME_OPT="${2:?--java-home needs a directory}"; shift 2 ;;
        --service-user)       SVC_USER="${2:?--service-user needs a name}"; shift 2 ;;
        -n|--dry-run)         DRY_RUN=true; shift ;;
        -y|--yes)             ASSUME_YES=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "Unknown option: $1 (see --help)" ;;
    esac
done

[ -n "$DB_HOST" ] && [ -n "$DB_SERVICE" ] || die "--db-host and --db-service are required (see --help)."
[[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port must be a port number."
[[ $DB_PORT =~ ^[0-9]+$ ]] || die "--db-port must be a port number."

[ "$(id -u)" -eq 0 ] || die "Run as root: it installs packages, creates a user and a service."
for tool in systemctl curl unzip tar runuser useradd; do
    command -v "$tool" >/dev/null 2>&1 || die "Needs '${tool}', which is not installed."
done
[ -f "${HERE}/ords-db.java" ] || die "ords-db.java must be in the same directory as this script."

# The settings ords-common.sh works from. The layout is fixed: it is the one
# ords-upgrade.sh handles best, and the point of installing with this script.
load_settings /etc/ords-upgrade.conf false
ORDS_SERVICE=ords
ORDS_HOME=/opt/ords
ORDS_VERSIONS_DIR=/opt/ords-versions
ORDS_CONFIG=/etc/ords/config
ORDS_LOG_FILE=""
SERVE_PORT="$PORT"
UNIT_FILE=/etc/systemd/system/ords.service
# Releases are probed before the service user exists; root is fine for that,
# against an empty config.
ORDS_USER=root

cd /

confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    [ -t 0 ] || die "Not running interactively; pass --yes to proceed without confirmation."
    local answer
    printf '    %s [y/N]: ' "$1"
    read -r answer
    case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) die "Stopped - nothing more was changed." ;; esac
}

read_secret_file() {
    [ -r "$1" ] || die "Cannot read ${1}."
    local v
    v="$(head -n1 "$1")"
    [ -n "$v" ] || die "${1} is empty."
    printf '%s' "$v"
}

# -----------------------------------------------------------------------------
#  Failure handling: take the local pieces back out, so a rerun starts clean
# -----------------------------------------------------------------------------
STAGING=""
CHANGED=false
CLEANING=false
DB_TOUCHED=false
CDN_SET=false

cleanup_failed_install() {
    CLEANING=true
    echo
    warn "The install failed - removing what it put on this server."
    systemctl disable --now ords >/dev/null 2>&1 || true
    if [ -f "$UNIT_FILE" ] && grep -q 'Installed by ords-install.sh' "$UNIT_FILE"; then
        rm -f "$UNIT_FILE"
        systemctl daemon-reload || true
    fi
    [ -L "$ORDS_HOME" ] && rm -f "$ORDS_HOME"
    [ -n "${NEW_DIR_FINAL:-}" ] && [ -d "$NEW_DIR_FINAL" ] && rm -rf "$NEW_DIR_FINAL"
    if [ -d "$ORDS_CONFIG" ]; then
        local aside
        aside="${ORDS_CONFIG}.failed-$(date +%Y%m%d-%H%M%S)"
        mv "$ORDS_CONFIG" "$aside"
        warn "The configuration it had written is in ${aside}, for reference."
    fi
    warn "Left in place: Java, the ${SVC_USER} user$([ "${PROXY_GENERATED:-false}" = true ] && echo ', and /root/.ords-public-user-pwd')."
    if [ "$DB_TOUCHED" = true ]; then
        warn "The database step had started: the ORDS schema may now be installed or upgraded$([ "$NEW_PROXY" = true ] && echo ", and ORDS_PUBLIC_USER has the new password")."
        warn "A rerun with the same --proxy-pwd-file picks up from there."
    fi
    [ "$CDN_SET" = false ] || warn "APEX's image prefix was switched to Oracle's CDN; that change stays."
    [ -z "${RUN_DIR:-}" ] || warn "Logs: ${RUN_DIR}"
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$CHANGED" = true ] && [ "$CLEANING" = false ]; then
        cleanup_failed_install || true
    fi
    [ -z "$STAGING" ] || rm -rf "$STAGING"
    [ -z "$PROBE_CFG" ] || rm -rf "$PROBE_CFG"
    exit "$rc"
}
trap on_exit EXIT

# -----------------------------------------------------------------------------
#  1. Nothing here already
# -----------------------------------------------------------------------------
if systemctl cat ords >/dev/null 2>&1; then
    die "This server already has an ords service. To check it, run ords-diag.sh;
     to upgrade it, ords-upgrade.sh. This script is for new servers only."
fi
for p in "$ORDS_HOME" "$ORDS_CONFIG"; do
    [ ! -e "$p" ] || die "${p} already exists. This script is for new servers only;
     move it aside first if it is left over from an earlier attempt."
done
if command -v ss >/dev/null 2>&1 && [ -n "$(ss -ltnH "sport = :${PORT}" 2>/dev/null)" ]; then
    die "Something is already listening on port ${PORT}. Choose another with --port."
fi

getent hosts "$DB_HOST" >/dev/null 2>&1 || die "${DB_HOST} does not resolve from this server."
timeout 5 bash -c "exec 3<>/dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null \
    || die "${DB_HOST}:${DB_PORT} does not accept connections from this server.
     On RDS, check the instance's security group allows this server on port ${DB_PORT}."
ok "Database listener ${DB_HOST}:${DB_PORT} is reachable"

# -----------------------------------------------------------------------------
#  2. Java
# -----------------------------------------------------------------------------
JAVA_INSTALLED_NOW=false
if [ -n "$JAVA_HOME_OPT" ]; then
    [ -x "${JAVA_HOME_OPT}/bin/java" ] || die "No ${JAVA_HOME_OPT}/bin/java."
    ORDS_JAVA_HOME="$JAVA_HOME_OPT"
elif [ -x /usr/lib/jvm/jre-21/bin/java ]; then
    # The alternatives link that follows dnf updates, not a versioned path.
    ORDS_JAVA_HOME=/usr/lib/jvm/jre-21
else
    command -v dnf >/dev/null 2>&1 || die "No Java 21 and no dnf to install it. Install Java 17 or later and pass --java-home."
    if [ "$DRY_RUN" = true ]; then
        die "Java 21 is not installed yet, and the dry run needs it to check the database.
     Install it first - it changes nothing else:
       sudo dnf install -y java-21-openjdk-headless
     then rerun the dry run."
    fi
    confirm "Java 21 is not installed. Install java-21-openjdk-headless with dnf, so the database can be checked?"
    log "Installing java-21-openjdk-headless"
    dnf -y -q install java-21-openjdk-headless
    JAVA_INSTALLED_NOW=true
    ORDS_JAVA_HOME=/usr/lib/jvm/jre-21
fi
JAVA_BIN="${ORDS_JAVA_HOME}/bin/java"
java_major="$("$JAVA_BIN" -version 2>&1 | sed -n 's/.*version "\([0-9]*\)\.\{0,1\}\([0-9]*\).*/\1 \2/p' | sed -n 1p | awk '{print ($1 == 1) ? $2 : $1}')"
[ "${java_major:-0}" -ge 17 ] || die "Java at ${ORDS_JAVA_HOME} is version ${java_major:-unknown}; ORDS needs 17 or later."
ORDS_ENV=("JAVA_HOME=${ORDS_JAVA_HOME}" "PATH=${ORDS_JAVA_HOME}/bin:${PATH}")
ok "Java ${java_major} at ${ORDS_JAVA_HOME}"

# -----------------------------------------------------------------------------
#  3. The release
# -----------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
chmod 711 "$BACKUP_DIR"
make_probe_dir

if [ -n "$ZIP_FILE" ]; then
    zip="$(readlink -f "$ZIP_FILE")"
    [ -f "$zip" ] || die "No such file: ${ZIP_FILE}"
else
    if [ "$WANT_VERSION" = latest ]; then
        name=ords-latest.zip
    else
        name="$(zip_name_for "$WANT_VERSION")" || die "--version ${WANT_VERSION} is not a full build number.
     Use it as 'ords --version' prints it (26.3.0.r2721811) or as the zip is
     named (26.3.0.272.1811)."
    fi
    mkdir -p "${BACKUP_DIR}/downloads"
    zip="${BACKUP_DIR}/downloads/${name}"
    download "${ORDS_DOWNLOAD_BASE}/${name}" "$zip"
fi
if [ -n "$ZIP_SHA256" ]; then
    [ "$(sha256sum "$zip" | awk '{print $1}')" = "${ZIP_SHA256,,}" ] || die "${zip} does not match --sha256."
    ok "Checksum matches"
fi

STAGING="$(mktemp -d /var/tmp/ords-install.XXXXXX)"
chmod 755 "$STAGING"
log "Unpacking"
unzip -q "$zip" -d "${STAGING}/ords" || die "${zip} is not a usable zip."
NEW_DIR="${STAGING}/ords"
[ -x "${NEW_DIR}/bin/ords" ] || die "${zip} does not contain bin/ords - is it an ORDS zip?"
NEW_VER="$(ords_version "$NEW_DIR")"
[ -n "$NEW_VER" ] || die "Could not read a version from the release."
ok "ORDS ${NEW_VER}"

# The JDBC driver for ords-db.java, from the release itself.
OJDBC="${STAGING}/ojdbc.jar"
unzip -p "${NEW_DIR}/ords.war" 'WEB-INF/lib/ojdbc11-*.jar' >"$OJDBC" 2>/dev/null && [ -s "$OJDBC" ] \
    || die "Could not find the Oracle JDBC driver in ${NEW_DIR}/ords.war."

# -----------------------------------------------------------------------------
#  4. The database, read-only
# -----------------------------------------------------------------------------
if [ -n "$ADMIN_PWD_FILE" ]; then
    ADMIN_PWD="$(read_secret_file "$ADMIN_PWD_FILE")"
elif [ -t 0 ]; then
    read -rsp "    Password for database user ${ADMIN_USER}: " ADMIN_PWD
    echo
else
    die "No password for ${ADMIN_USER}: pass --admin-pwd-file."
fi
[ -n "$ADMIN_PWD" ] || die "The password for ${ADMIN_USER} is empty."
JDBC_USER="$ADMIN_USER"
[ "${ADMIN_USER^^}" = SYS ] && JDBC_USER="SYS AS SYSDBA"

# ords_db COMMAND [EXTRA-STDIN-LINE] - as the admin user.
ords_db() {
    printf '%s\n' "$ADMIN_PWD" ${2+"$2"} | "$JAVA_BIN" -cp "$OJDBC" "${HERE}/ords-db.java" \
        "$1" "$DB_HOST" "$DB_PORT" "$DB_SERVICE" "$JDBC_USER"
}

# Can ORDS_PUBLIC_USER log in with this password? The same test the pool
# makes when ORDS starts, done before anything is installed.
proxy_login_ok() {
    local out
    out="$(printf '%s\n' "$1" | "$JAVA_BIN" -cp "$OJDBC" "${HERE}/ords-db.java" \
        check "$DB_HOST" "$DB_PORT" "$DB_SERVICE" ORDS_PUBLIC_USER)" && return 0
    PROXY_LOGIN_ERROR="$(sed -n 's/^error=//p' <<<"$out")"
    return 1
}

log "Checking the database as ${ADMIN_USER}"
db_out="$(ords_db check)" || die "Could not log in to ${DB_HOST}:${DB_PORT}/${DB_SERVICE} as ${ADMIN_USER}:
     $(sed -n 's/^error=//p' <<<"$db_out")
     Nothing has been installed$([ "$JAVA_INSTALLED_NOW" = true ] && echo ' apart from Java')."
dbv() { sed -n "s/^$1=//p" <<<"$db_out" | sed -n 1p; }
DB_VERSION="$(dbv db_version)"
APEX_VERSION="$(dbv apex_version)"
ORDS_SCHEMA="$(dbv ords_schema)"
ORDS_SCHEMA_VERSION="$(dbv ords_schema_version)"
APUB_STATUS="$(dbv apex_public_user_status)"
IMAGE_PREFIX="$(dbv image_prefix)"
ok "Logged in. Oracle ${DB_VERSION:-?}, APEX ${APEX_VERSION:-not installed}, ORDS schema: ${ORDS_SCHEMA_VERSION:-${ORDS_SCHEMA}}"

JOINING=false
[ "$ORDS_SCHEMA" = yes ] && JOINING=true

# --- The ORDS_PUBLIC_USER password ------------------------------------------
PROXY_GENERATED=false
PROXY_PWD_SAVE=/root/.ords-public-user-pwd
if [ -n "$PROXY_PWD_FILE" ]; then
    PROXY_PWD="$(read_secret_file "$PROXY_PWD_FILE")"
elif [ "$JOINING" = true ]; then
    die "ORDS is already installed in this database. This server connects to it as
     ORDS_PUBLIC_USER, so it needs that user's password: the one the other ORDS
     servers have. Pass it with --proxy-pwd-file.

     If nobody knows it, choose a new one, put it in a file, and pass that with
     --proxy-pwd-file and --new-proxy-password. The installer then sets it in the
     database, and the other servers' pools stop working until each is given it."
else
    # Upper, lower and digits in every password, for databases whose password
    # profile demands all three; nothing that needs quoting anywhere.
    PROXY_PWD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22 || true)Ax9"
    PROXY_GENERATED=true
fi

if [ "$JOINING" = true ] && [ "$NEW_PROXY" = false ]; then
    proxy_login_ok "$PROXY_PWD" || die "ORDS_PUBLIC_USER cannot log in with the password in ${PROXY_PWD_FILE}:
     ${PROXY_LOGIN_ERROR:-unknown error}
     Use the password the other ORDS servers on this database have, or pass
     --new-proxy-password to set a new one. Nothing has been installed$([ "$JAVA_INSTALLED_NOW" = true ] && echo ' apart from Java')."
    ok "ORDS_PUBLIC_USER logs in with the password in ${PROXY_PWD_FILE}"
fi
[[ $PROXY_PWD != *'"'* ]] || die "The ORDS_PUBLIC_USER password must not contain a double quote."

# --- APEX --------------------------------------------------------------------
GATEWAY=disabled
SET_CDN=false
UNLOCK_APUB=false
APEX_NOTE=""
if [ "$APEX" = true ] && [ -n "$APEX_VERSION" ]; then
    GATEWAY=proxied
    case "$IMAGE_PREFIX" in
        https://static.oracle.com/cdn/apex/"${APEX_VERSION}"/)
            APEX_NOTE="static files already come from Oracle's CDN" ;;
        ""|/i/)
            if [ "$JOINING" = false ] || [ "$APEX_CDN" = true ]; then
                SET_CDN=true
                APEX_NOTE="static files will come from Oracle's CDN (https://static.oracle.com/cdn/apex/${APEX_VERSION}/)"
            else
                APEX_NOTE="WARNING: APEX expects its static files at /i/ on each ORDS server, and this one will not serve them. Pass --apex-cdn to switch the database to Oracle's CDN (it affects every server on this database)"
            fi ;;
        *)
            APEX_NOTE="static files come from ${IMAGE_PREFIX} (left as it is)" ;;
    esac
    # ORDS reaches APEX by proxying through APEX_PUBLIC_USER, so a locked
    # account fails every APEX page with HTTP 570 - and RDS often ships it
    # locked. Unlocking is enough (tested). An expired password is not
    # something this script could test, so it is reported, not changed.
    case "$APUB_STATUS" in
        ""|OPEN) ;;
        *EXPIRED*)
            APEX_NOTE="${APEX_NOTE}; WARNING: APEX_PUBLIC_USER is ${APUB_STATUS} - if APEX pages fail with HTTP 570, give it a new password: alter user apex_public_user identified by \"<new password>\" account unlock;"
            [[ $APUB_STATUS == *LOCKED* ]] && UNLOCK_APUB=true ;;
        *LOCKED*)
            UNLOCK_APUB=true
            APEX_NOTE="${APEX_NOTE}; APEX_PUBLIC_USER is ${APUB_STATUS} and will be unlocked (APEX needs it)" ;;
        *)
            APEX_NOTE="${APEX_NOTE}; APEX_PUBLIC_USER is ${APUB_STATUS}" ;;
    esac
elif [ "$APEX" = true ]; then
    APEX_NOTE="APEX is not installed in this database, so ORDS is set up for REST services only"
else
    APEX_NOTE="not used (--no-apex)"
fi

# --- Versions ----------------------------------------------------------------
SCHEMA_NOTE=""
if [ "$JOINING" = true ] && [ -n "$ORDS_SCHEMA_VERSION" ]; then
    if ver_lt "$NEW_VER" "$ORDS_SCHEMA_VERSION"; then
        die "The database's ORDS schema is ${ORDS_SCHEMA_VERSION}, newer than ${NEW_VER}.
     ORDS schemas do not go backwards. Install the matching release instead:
       --version ${ORDS_SCHEMA_VERSION}"
    elif [ "$NEW_VER" != "$ORDS_SCHEMA_VERSION" ]; then
        SCHEMA_NOTE="the ORDS schema goes from ${ORDS_SCHEMA_VERSION} to ${NEW_VER} for EVERY server on this database. Upgrade them straight after with ords-upgrade.sh, or install --version ${ORDS_SCHEMA_VERSION} to match them"
    fi
fi

# -----------------------------------------------------------------------------
#  5. The plan
# -----------------------------------------------------------------------------
yesno() { [ "$1" = true ] && echo on || echo off; }
echo
log "ORDS install plan"
printf '    %-14s %s\n' \
    "release"      "ORDS ${NEW_VER} -> ${ORDS_VERSIONS_DIR}/${NEW_VER}, linked as ${ORDS_HOME}" \
    "config"       "$ORDS_CONFIG" \
    "service"      "ords.service as ${SVC_USER}$(id "$SVC_USER" >/dev/null 2>&1 || echo ' (created)'), port ${PORT}, starts at boot" \
    "java"         "$ORDS_JAVA_HOME" \
    "database"     "${DB_HOST}:${DB_PORT}/${DB_SERVICE}, Oracle ${DB_VERSION:-?}" \
    "ORDS schema"  "$([ "$JOINING" = true ] && echo "join the existing one (${ORDS_SCHEMA_VERSION:-version unknown})" || echo "install it, as ${ADMIN_USER}")" \
    "ORDS user pwd" "$([ "$PROXY_GENERATED" = true ] && echo "generated, saved to ${PROXY_PWD_SAVE}" || echo "from ${PROXY_PWD_FILE:-?}$([ "$NEW_PROXY" = true ] && echo ' - NEW: the other servers must be given it')")" \
    "APEX"         "$([ "$GATEWAY" = proxied ] && echo "APEX ${APEX_VERSION}; ${APEX_NOTE}" || echo "$APEX_NOTE")" \
    "Database Actions" "$(yesno "$DB_ACTIONS")"
[ -z "$SCHEMA_NOTE" ] || printf '    %-14s %s\n' "WARNING" "$SCHEMA_NOTE"
if [ "$JOINING" = true ] && [ "$NEW_PROXY" = true ]; then
    printf '    %-14s %s\n' "WARNING" "ORDS_PUBLIC_USER gets a NEW password in the database. Every other ORDS server" \
        "" "on it stops serving until it is given the same password and restarted:" \
        "" "  sudo -u <ords user> /opt/ords/bin/ords --config <config dir> config secret --password-stdin db.password < <file>" \
        "" "  sudo systemctl restart ords"
fi
echo

if [ "$DRY_RUN" = true ]; then
    ok "Dry run - nothing was installed."
    exit 0
fi
confirm "Install ORDS ${NEW_VER}?"

# -----------------------------------------------------------------------------
#  6. Install
# -----------------------------------------------------------------------------
CHANGED=true
RUN_DIR="${BACKUP_DIR}/install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${RUN_DIR}/install-logs"
chmod 711 "$RUN_DIR"
exec > >(tee -a "${RUN_DIR}/install.log") 2>&1

if ! id "$SVC_USER" >/dev/null 2>&1; then
    log "Creating the ${SVC_USER} system user"
    useradd --system --user-group --home-dir "/var/lib/${SVC_USER}" --create-home \
        --shell /sbin/nologin --comment "Oracle REST Data Services" "$SVC_USER"
fi
ORDS_USER="$SVC_USER"
chown "$SVC_USER" "${RUN_DIR}/install-logs"

# Binaries belong to root and are only read by the service: a compromised ORDS
# cannot rewrite the code it runs.
mkdir -p "$ORDS_VERSIONS_DIR"
NEW_DIR_FINAL="${ORDS_VERSIONS_DIR}/${NEW_VER}"
rm -rf "$NEW_DIR_FINAL"
mv "$NEW_DIR" "$NEW_DIR_FINAL"
chown -R root:root "$NEW_DIR_FINAL"
chmod -R u=rwX,go=rX "$NEW_DIR_FINAL"
ln -sfn "$NEW_DIR_FINAL" "$ORDS_HOME"
ok "${ORDS_HOME} -> ${NEW_DIR_FINAL}"

mkdir -p "$ORDS_CONFIG"
chmod 755 "$(dirname "$ORDS_CONFIG")"
chown "${SVC_USER}:${SVC_USER}" "$ORDS_CONFIG"
chmod 750 "$ORDS_CONFIG"

if [ "$PROXY_GENERATED" = true ]; then
    ( umask 077; printf '%s\n' "$PROXY_PWD" >"$PROXY_PWD_SAVE" )
    ok "ORDS_PUBLIC_USER password saved to ${PROXY_PWD_SAVE} - other servers on this database need it"
fi

if [ "$JOINING" = true ] && [ "$NEW_PROXY" = true ]; then
    log "Setting ORDS_PUBLIC_USER's new password in the database"
    DB_TOUCHED=true
    pwd_out="$(ords_db set-ords-public-password "$PROXY_PWD")" \
        || die "Could not set ORDS_PUBLIC_USER's password: $(sed -n 's/^error=//p' <<<"$pwd_out")"
    ok "ORDS_PUBLIC_USER has the new password. Give it to the other ORDS servers now."
fi

log "Running 'ords install' $([ "$JOINING" = true ] && echo "(joining the existing ORDS schema)" || echo "(installing the ORDS schema)")"
install_args=(--config "$ORDS_CONFIG" install
    --admin-user "$JDBC_USER"
    --proxy-user
    --db-hostname "$DB_HOST" --db-port "$DB_PORT" --db-servicename "$DB_SERVICE"
    # ORDS refuses Database Actions without the Database API behind it.
    --feature-sdw "$DB_ACTIONS" --feature-rest-enabled-sql "$DB_ACTIONS" --feature-db-api "$DB_ACTIONS"
    --gateway-mode "$GATEWAY"
    --log-folder "${RUN_DIR}/install-logs"
    --password-stdin)
[ "$GATEWAY" = proxied ] && install_args+=(--gateway-user APEX_PUBLIC_USER)
DB_TOUCHED=true
# Passwords on stdin, in the order ords asks: admin first, then ORDS_PUBLIC_USER.
printf '%s\n%s\n' "$ADMIN_PWD" "$PROXY_PWD" | run_ords "$ORDS_HOME" "${install_args[@]}" 2>&1 \
    | tee "${RUN_DIR}/install-logs/ords-install.out" \
    || die "'ords install' failed. Its output: ${RUN_DIR}/install-logs/ords-install.out"
ok "ORDS is configured"

if [ "$SET_CDN" = true ]; then
    log "Pointing APEX at Oracle's CDN"
    if cdn_out="$(ords_db set-cdn)"; then
        CDN_SET=true
        ok "APEX image prefix: $(sed -n 's/^image_prefix=//p' <<<"$cdn_out")"
    else
        warn "Could not set APEX's image prefix: $(sed -n 's/^error=//p' <<<"$cdn_out")"
        warn "APEX pages will load without their styles until it is set. As a user with"
        warn "APEX_ADMINISTRATOR_ROLE, run:"
        warn "  exec apex_instance_admin.set_parameter('IMAGE_PREFIX', 'https://static.oracle.com/cdn/apex/${APEX_VERSION}/'); commit;"
    fi
fi

if [ "$UNLOCK_APUB" = true ]; then
    log "Unlocking APEX_PUBLIC_USER"
    if apub_out="$(ords_db unlock-apex-public)"; then
        ok "APEX_PUBLIC_USER is now $(sed -n 's/^apex_public_user_status=//p' <<<"$apub_out")"
    else
        warn "Could not unlock APEX_PUBLIC_USER: $(sed -n 's/^error=//p' <<<"$apub_out")"
        warn "APEX pages will fail with HTTP 570 until it is unlocked:"
        warn "  alter user apex_public_user account unlock;"
    fi
fi

log "Writing ${UNIT_FILE}"
cat >"$UNIT_FILE" <<EOF
# Installed by ords-install.sh (https://github.com/juliusbsimon/ords-tools).
# ords-upgrade.sh switches ${ORDS_HOME} to new releases; this file stays as it is.
[Unit]
Description=Oracle REST Data Services
Documentation=https://github.com/juliusbsimon/ords-tools
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
Environment=JAVA_HOME=${ORDS_JAVA_HOME}
ExecStart=${ORDS_HOME}/bin/ords --config ${ORDS_CONFIG} serve --port ${PORT}
# 143 is how the JVM exits on SIGTERM: a normal stop, not a failure.
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
$( [ "$PORT" -lt 1024 ] && printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\n' )
# Trims what a compromised ORDS could reach. It needs to write nowhere but its
# configuration and its own home.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${ORDS_CONFIG}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ords >/dev/null 2>&1

log "Starting ORDS"
HEALTH_URLS="$(default_health_urls)"
systemctl start ords
healthy || die "ORDS did not come up healthy. See: journalctl -u ords"

if [ "$GATEWAY" = proxied ]; then
    cookies="$(mktemp)"
    code="$(curl -ks -L --max-redirs 5 -c "$cookies" -b "$cookies" -o /dev/null -w '%{http_code}' --max-time 30 \
            "$(ords_origin)$(ords_context)/apex" || true)"
    rm -f "$cookies"
    if [ "$code" = 200 ]; then
        ok "APEX answers on $(ords_context)/apex"
    elif [ "$code" = 570 ]; then
        warn "APEX answered HTTP 570: ORDS cannot proxy through APEX_PUBLIC_USER."
        warn "It is usually locked or its password has expired. Check with:"
        warn "  select account_status from dba_users where username = 'APEX_PUBLIC_USER';"
    else
        warn "APEX answered HTTP ${code:-nothing} on $(ords_context)/apex - check: journalctl -u ords"
    fi
fi

# So ords-upgrade.sh and ords-diag.sh know who installs the schema. No password
# is written: the admin password file, if one was used, is referenced only.
if [ ! -f /etc/ords-upgrade.conf ]; then
    ( umask 077
      printf '# Written by ords-install.sh. See ords-upgrade.conf.example for every setting.\n'
      printf 'ORDS_ADMIN_USER=%s\n' "$ADMIN_USER"
      [ -z "$ADMIN_PWD_FILE" ] || printf 'ORDS_ADMIN_PWD_FILE=%s\n' "$(readlink -f "$ADMIN_PWD_FILE")"
      printf '# Set this to have ords-upgrade.sh snapshot the RDS instance first.\n'
      printf 'RDS_INSTANCE_ID=\n'
    ) >/etc/ords-upgrade.conf
    chmod 600 /etc/ords-upgrade.conf
    ok "Wrote /etc/ords-upgrade.conf for ords-upgrade.sh"
fi

CHANGED=false
echo
ok "ORDS ${NEW_VER} is installed and running on port ${PORT}."
log "Check it:        ${HERE}/ords-diag.sh"
log "Upgrade it:      ${HERE}/ords-upgrade.sh --dry-run"
[ "$PROXY_GENERATED" = false ] || log "Other servers:   install with --proxy-pwd-file holding the password in ${PROXY_PWD_SAVE}"
log "Record:          ${RUN_DIR}"
