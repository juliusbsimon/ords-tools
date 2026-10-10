# Installing ORDS on a new server

`ords-install.sh` sets up ORDS on a new Linux server, in the layout the other
two scripts expect. `ords-diag.sh` passes on the first run, and
`ords-upgrade.sh` works with no preparation.

It works for the first ORDS server on a database, where it installs the ORDS
schema, and for every server after that, where it joins the schema that is
already there.

---

## Contents

1. [What you get](#1-what-you-get)
2. [Before you start](#2-before-you-start)
3. [Install, step by step](#3-install-step-by-step)
4. [The first server and the ones after it](#4-the-first-server-and-the-ones-after-it)
5. [APEX](#5-apex)
6. [Options](#6-options)
7. [When an install fails](#7-when-an-install-fails)
8. [After the install](#8-after-the-install)
9. [How it was tested](#9-how-it-was-tested)

---

## 1. What you get

| Path | What |
|---|---|
| `/opt/ords-versions/<build>/` | The ORDS release, owned by root. The service can read it but not change it |
| `/opt/ords` | A link to the release. `ords-upgrade.sh` moves this link to new releases |
| `/etc/ords/config/` | The ORDS configuration, owned by the service user and readable by nobody else |
| `/etc/systemd/system/ords.service` | The service. It starts at boot, runs as the `ords` system user, and restarts ORDS if it crashes |
| `/usr/lib/jvm/jre-21` | Java 21 from dnf, so it gets security fixes with your normal OS updates |
| `/etc/ords-upgrade.conf` | Settings for `ords-upgrade.sh` and `ords-diag.sh`: the admin user, and where its password file is |
| `/var/backups/ords-upgrade/install-<time>/` | The install's log, including what `ords install` printed |

ORDS listens on plain HTTP, on port 8080 by default. Database Actions (SQL
Developer Web) and REST-enabled SQL are off unless you ask for them.

---

## 2. Before you start

- **A server** running Oracle Linux 9, or another system with dnf and systemd.
  It has been tested on Oracle Linux 9 only.
- **Root,** through `sudo`.
- **A database the server can reach.** On RDS, the instance's security group
  must allow this server on port 1521. The installer checks this first.
- **The admin user and its password.** On RDS this is the master user. On a
  self-managed database it is SYS.
- **If ORDS is already in the database,** you need the `ORDS_PUBLIC_USER`
  password the other ORDS servers use. See
  [section 4](#4-the-first-server-and-the-ones-after-it).
- **Internet access** to download Java and ORDS. Without it, install Java from
  your own repository, download the ORDS zip elsewhere, and pass `--zip`.

---

## 3. Install, step by step

**1. Download the scripts:**

```bash
mkdir -p ~/ords-tools && curl -fsSL https://github.com/juliusbsimon/ords-tools/archive/refs/tags/v1.1.0.tar.gz | tar xz -C ~/ords-tools --strip-components=1
cd ~/ords-tools
```

**2. Store the admin password** in a file only root can read:

```bash
sudo bash -c 'read -rsp "Password: " p; echo; printf "%s\n" "$p" > /root/.ords-admin-pwd; chmod 600 /root/.ords-admin-pwd'
```

**3. Install Java,** so the dry run can check the database:

```bash
sudo dnf install -y java-21-openjdk-headless
```

You can skip this step. The real install asks before installing Java itself;
only the dry run needs Java to be there already.

**4. Do a dry run.** It checks the database connection, logs in as the admin
user, and prints the plan. It installs nothing.

```bash
sudo ./ords-install.sh --db-host mydb.abc123.us-east-2.rds.amazonaws.com --db-service ORCL \
    --admin-user admin --admin-pwd-file /root/.ords-admin-pwd --dry-run
```

Read the `ORDS schema` line. It says whether this server installs the ORDS
schema or joins one that is there. Read any `WARNING` lines too.

**5. Install.** Run the same command without `--dry-run`. It asks once, then
installs, starts ORDS, and checks that every pool is `VALID` and that APEX
answers.

**6. Check it:**

```bash
sudo ./ords-diag.sh
```

Expect `READY_WITH_WARNINGS`, where the one warning is that `RDS_INSTANCE_ID`
is not set. Set it in `/etc/ords-upgrade.conf` if you want `ords-upgrade.sh` to
snapshot the database before each upgrade.

---

## 4. The first server and the ones after it

Every ORDS server connects to the database as `ORDS_PUBLIC_USER`, so all the
servers on one database need that user's password.

**The first server** installs the ORDS schema and creates `ORDS_PUBLIC_USER`.
The installer generates a password and saves it in
`/root/.ords-public-user-pwd`. Keep a copy somewhere safe: every later server
needs it.

**Later servers** join the schema that is there. Copy the password file to the
new server and pass it:

```bash
sudo ./ords-install.sh ... --proxy-pwd-file /root/.ords-public-user-pwd
```

The installer logs in as `ORDS_PUBLIC_USER` with it before installing
anything. A wrong password stops the install there, and the other servers are
not affected.

**If nobody knows the password,** for example when ORDS was set up by hand
years ago, choose a new one, put it in a file, and pass `--new-proxy-password`
as well. The installer sets the new password in the database. From that
moment every other ORDS server on the database stops serving, until it is
given the same password and restarted. On each of them, as the user ORDS runs
as:

```bash
sudo -u ords /opt/ords/bin/ords --config /etc/ords/config config secret --password-stdin db.password < new-password-file
sudo systemctl restart ords
```

Use that server's own ORDS path, config directory and service user; the plan
prints the command. If its Java is not on the path, put `JAVA_HOME=/path/to/jdk`
after `sudo -u ords`. Run `ords-diag.sh` on each one afterwards:
`pool.default.status` should be VALID.

**Versions.** A joining server should run the same ORDS release as the
database's ORDS schema. If the database is newer, the installer refuses and
names the `--version` to use. If the database is older, installing upgrades
the schema for every server on it. The plan says so as a `WARNING`, and you
can either upgrade the others with `ords-upgrade.sh` straight after, or pass
`--version` to match them.

---

## 5. APEX

If the database has APEX, the installer sets up ORDS to serve it, and deals
with two things that commonly break it:

- **Static files.** APEX needs its images, CSS and JavaScript from somewhere.
  On a database where APEX still uses the default `/i/` and ORDS is new, the
  installer points APEX at Oracle's CDN, for the exact APEX version in the
  database. When ORDS is already in the database, it leaves the setting alone,
  because it affects every server. If the setting is `/i/` there, the plan
  warns that this server will not serve those files, and `--apex-cdn` switches
  it.
- **`APEX_PUBLIC_USER`.** ORDS reaches APEX through this account. If it is
  locked, as it often is on RDS, every APEX page fails with HTTP 570. The
  installer unlocks it, and the plan says so first. If its password has
  expired, the plan warns and gives the SQL to fix it; the installer does not
  change it, because that case could not be tested.

With `--no-apex`, or when the database has no APEX, ORDS serves REST services
only.

---

## 6. Options

| Option | What it does |
|---|---|
| `--db-host HOST` | Database host. Required |
| `--db-port N` | Listener port. Default 1521 |
| `--db-service NAME` | Database service name. Required |
| `--admin-user USER` | The RDS master user, or SYS. Default `admin` |
| `--admin-pwd-file FILE` | That user's password. Prompted for when not given |
| `--proxy-pwd-file FILE` | The `ORDS_PUBLIC_USER` password. Required when joining |
| `--new-proxy-password` | When joining, set that password as a new one in the database |
| `--port N` | HTTP port. Default 8080. Ports below 1024 work too |
| `--version V` | A specific ORDS build, such as `26.3.0.r2721811`. Default: the latest |
| `--zip FILE` | Install this ORDS zip instead of downloading one |
| `--sha256 HEX` | Refuse a zip that does not match |
| `--no-apex` | No APEX: REST services only |
| `--apex-cdn` | Switch APEX to Oracle's CDN even when other servers share the database |
| `--database-actions` | Turn on Database Actions, with the REST-enabled SQL and Database API it needs |
| `--java-home DIR` | Use this Java instead of installing it from dnf |
| `--service-user NAME` | Default `ords` |
| `--dry-run` | Check everything and print the plan. Installs nothing |
| `--yes` | Do not ask for confirmation |

---

## 7. When an install fails

If something fails after the install has started, the installer removes what
it put on the server: the service, the `/opt/ords` link and the release.
It moves the configuration aside to `/etc/ords/config.failed-<time>`, so you
can see what was written. It keeps Java and the `ords` user, which a rerun
reuses.

It also says whether the database was changed. If `ords install` had run, the
ORDS schema may now be installed. A rerun with the same options picks up from
there.

Look in `/var/backups/ords-upgrade/install-<time>/` for the log, and at
`journalctl -u ords` when ORDS itself did not start.

Problems found before the install starts stop it with nothing changed. That
covers an unreachable database, a wrong admin or `ORDS_PUBLIC_USER` password,
and a release older than the database's schema.

---

## 8. After the install

- **HTTPS.** ORDS listens on plain HTTP. Put a load balancer with a
  certificate in front of it, such as an AWS Application Load Balancer, and
  allow only the load balancer to reach port 8080.
- **Upgrades.** `ords-upgrade.sh` works straight away; see
  [GUIDE.md](GUIDE.md).
- **Java updates.** Java comes from dnf, so `dnf update` patches it. Restart
  ORDS afterwards (`sudo systemctl restart ords`) so it runs on the new
  version.

---

## 9. How it was tested

On Oracle Linux 9 containers with real systemd, against Oracle 21c with
APEX 26.1, installing ORDS 26.3.0:

- the first server: Java installed from dnf, ORDS schema installed, APEX
  switched to the CDN, service started, and the diagnostic passing
- a second server joining with the password, and the first server still
  `VALID` afterwards
- joining without the password, and with a wrong one: both refused with
  nothing installed
- `--new-proxy-password`: the new password set in the database, another
  server failing until given it, then recovering
- a release older than the database's schema: refused, naming the right
  `--version`
- a failure part-way: the server cleaned up, and a rerun succeeding
- `APEX_PUBLIC_USER` locked: unlocked by the installer, APEX answering
- port 80, `--no-apex` and `--database-actions`
- `ords-upgrade.sh --force` and `--rollback` on an installed server

Not tested: RDS (the master user's privileges for a fresh schema install have
not been checked), Oracle Linux 8 or RHEL, and an expired `APEX_PUBLIC_USER`
password.
