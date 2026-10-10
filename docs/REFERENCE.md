# Reference

What the two scripts do, their options, and how they were tested. For the
procedure, see [GUIDE.md](GUIDE.md).

| File | What it does |
|---|---|
| `ords-diag.sh` | Checks the server and says whether an upgrade can run now. Changes nothing. |
| `ords-upgrade.sh` | Upgrades ORDS, one run at a time, when you run it. Nothing is scheduled. |
| `ords-common.sh` | Shared by both. Keep it in the same directory. |
| `ords-upgrade.conf.example` | Settings, for `/etc/ords-upgrade.conf`. |

```bash
cd ~/ords-tools
sudo cp ords-upgrade.conf.example /etc/ords-upgrade.conf
sudo chmod 600 /etc/ords-upgrade.conf     # then set ORDS_ADMIN_USER, the password file and RDS_INSTANCE_ID
sudo ./ords-diag.sh                       # is this server ready?
sudo ./ords-upgrade.sh --dry-run          # what exactly would the upgrade do?
sudo ./ords-upgrade.sh                    # asks once, then upgrades
```

## The diagnostic

`ords-diag.sh` runs about 30 checks and ends with a verdict:

| Verdict | Exit status | Meaning |
|---|---|---|
| `READY` | 0 | Nothing in the way |
| `READY_WITH_WARNINGS` | 1 | The upgrade will run. Read the WARN lines first |
| `NOT_READY` | 2 | A FAIL line will stop the upgrade or make it roll back |

Each check has a fixed id, such as `pool.default.status` or
`upgrade.db_snapshot`, and a status: PASS, WARN, FAIL or INFO. `--json`
prints the same checks as JSON.

It covers six areas:

- **Install:** version, layout, Java, and anything that would make the upgrade
  refuse to run.
- **Service:** running or not, crash restarts, starts at boot, who holds the
  port.
- **Configuration:** file ownership, wallets, and whether each pool's
  database host resolves and accepts connections.
- **Last start:** the pool table ORDS logged, with the ORA- error and a hint
  for any pool that is not `VALID`.
- **HTTP:** the base URL, a request that needs the database, and APEX when
  the pool serves it.
- **Upgrade readiness:** disk space, the password file, whether the RDS
  instance exists and matches a pool, and how the last upgrade ended.

It never downloads anything, logs into a database, or starts or stops ORDS.
Two checks leave the server: a HEAD request to Oracle's download site and
`aws rds describe-db-instances`. `--offline` skips both.

The pool check matters most. The upgrade judges the new version by the same
pool table, so a pool that is `INVALID` now makes every upgrade roll back.
Fix it first.

## Asking an agent for advice

An agent can run the diagnostic and advise you. These are the rules to give
it:

- **Run on its own:** `sudo ./ords-diag.sh --json`. Read-only, safe at any
  time.
- **Run on its own, once the verdict is not `NOT_READY`:**
  `sudo ./ords-upgrade.sh --dry-run`. It downloads the new release to
  `/var/backups/ords-upgrade/downloads` and prints the plan. It does not touch
  the service, the config or the database.
- **Needs you:** `ords-upgrade.sh` without `--dry-run`, and `--rollback`.
  Both stop ORDS, and the upgrade changes the database schema for every ORDS
  server using that database. The agent recommends; you run them.
- **Read-only evidence it may use:** `journalctl -u ords`,
  `/var/log/ords/ords.log` (RPM installs), and
  `/var/backups/ords-upgrade/<run>/upgrade.log` from earlier runs.

The FAIL and WARN details say what to fix, and the ORA- hints cover the usual
causes of an `INVALID` pool. `upgrade.other_servers` is always there as a
reminder. The diagnostic cannot see other ORDS servers on the same database,
so the agent should ask you about them.

## What a run does

1. Reads the systemd unit to find the ORDS directory, the config directory,
   the service user and the Java it uses. `--dry-run` prints all of it.
2. Downloads `ords-latest.zip` from Oracle, or the release you name with
   `--version`. On an RPM install it asks dnf instead. It runs the new
   release's `ords --version` as the service user, so a Java that is too old
   fails here, before anything changes.
3. Takes an RDS snapshot if `RDS_INSTANCE_ID` is set, and waits for it.
4. Backs up the ORDS config directory, including the pool wallets.
5. Stops the service and switches to the new release.
6. Runs `ords install` through each pool. With an existing install, that
   command upgrades the ORDS schema in the database.
7. Starts the service. It waits for ORDS to log its pool table, and fails if
   any pool is not `VALID`. Then it checks the health URLs.
8. If any step from 5 on fails, it rolls back on its own: old binaries, old
   config, service restarted.

Every run leaves a record in `/var/backups/ords-upgrade/<timestamp>/`: the
log, the config backup, the `ords install` logs and a state file.

## Install layouts it handles

| Layout | How it looks | What the upgrade does |
|---|---|---|
| symlink | `/opt/oracle/ords` is a symlink into `ords-versions/<build>` | Unpacks the new release next to the old one and moves the symlink |
| plain | `/opt/oracle/ords` is an unpacked zip | The first time, moves it to `ords-versions/<build>` and puts a symlink in its place. After that it is the symlink layout |
| rpm | Installed from Oracle's yum repo | `dnf install ords-<version>`; rollback is `dnf downgrade` |

The unit keeps pointing at the same path in every case, so the unit file is
never edited.

It refuses to start, before changing anything, in three cases:

- The ORDS config directory is inside the ORDS directory.
- A setting or a unit argument points inside the ORDS directory, for example
  `--apex-images /opt/oracle/ords/images`. A new release would not have those
  files.
- The unit runs ORDS from a directory named after a version, such as
  `/opt/oracle/ords-24.4`. That path cannot become the stable symlink. The
  error message gives the three commands that fix it.

## The database part cannot be undone by this script

The ORDS schema only moves forward. `--rollback` and the automatic rollback
put back the binaries and config, but the schema stays on the new version.
The only way back for the database is the RDS snapshot, so set
`RDS_INSTANCE_ID`. Restoring an RDS snapshot creates a new instance with a new
endpoint, so the pool's `db.hostname` has to change too.

In testing, ORDS 24.4 ran APEX without errors against a 26.2.3 schema after a
rollback. That is one combination, not a promise.

## Several ORDS servers on one database

All the servers share one ORDS schema. Upgrade all of them in the same
window. The first server upgrades the schema. On the others, `ords install`
finds the schema already current and only the binaries change.

`ords install` also resets `ORDS_PUBLIC_USER`'s database password to the one
in that server's wallet if the two differ. If servers have different wallet
passwords, the last one upgraded wins and the other servers' pools go
`INVALID`. Keep the passwords the same on every server.

## On RDS

- `ORDS_ADMIN_USER` is the master user. RDS has no SYS.
- If `ords install` fails with `ORA-01031: insufficient privileges`, the
  master user is missing a grant ORDS needs. AWS's page on setting up ORDS
  for RDS for Oracle lists the grants.
- The snapshot needs the aws CLI on the ORDS server, with
  `rds:CreateDBSnapshot` and `rds:DescribeDBSnapshots`.

## Options

```text
--dry-run          download and inspect the new release, print the plan, stop
--version V        a specific release: 26.2.1.r1901402 or 26.2.1.190.1402 (zip), 26.2.3 (rpm)
--zip FILE         use this zip instead of downloading, for servers with no internet access
--sha256 HEX       refuse a zip that does not match
--yes              do not ask for confirmation
--force            reinstall the same version, or allow a downgrade
--rollback         undo the last successful upgrade (binaries and config only)
--conf FILE        settings file (default /etc/ords-upgrade.conf)
```

All settings are in [ords-upgrade.conf.example](../ords-upgrade.conf.example).

## How it was tested

Tested on Oracle Linux 9 containers running real systemd, against an Oracle
21c database with APEX 26.1.

The upgrade:

- zip, plain layout: 24.4.0 to 26.2.3, including the first-time move to the
  symlink layout
- a wrong admin password: the upgrade stopped at the schema step and rolled
  back to 24.4
- a pool that cannot connect: the upgrade was caught as `INVALID` and rolled
  back
- `--rollback`, a rerun that has nothing to do, and `--force`
- RPM: 26.2.2 to 26.2.3 through dnf, then `--rollback` through `dnf downgrade`

The diagnostic, on both layouts:

- healthy: `READY_WITH_WARNINGS` (no RDS snapshot configured), and `READY`
  once everything passes
- a pool with the wrong password: `NOT_READY`, with ORA-01017 and its hint
- service stopped, a config file the service user cannot read, and
  `--apex-images` inside the ORDS directory: each reported as FAIL
- a unit that does not exist: `NOT_READY`, still valid JSON
- after a successful upgrade and after a failed one: the last run's outcome,
  including whether the database was touched
- the RDS check against a stub `aws`: instance matches a pool, instance does
  not match, and instance not found

Against real RDS (2026-10-10): an EC2 server with a plain zip install,
upgraded from 26.1.0 to 26.3.0 with the RDS master user as `ORDS_ADMIN_USER`,
then the diagnostic, with every check passing. The script's own RDS snapshot
and the diagnostic's `describe-db-instances` check have still only run against
a stub `aws`: that run used a snapshot taken in the console.
