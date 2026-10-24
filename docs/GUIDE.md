# Upgrading ORDS on your servers

How to upgrade ORDS on a server where it runs under systemd. Two scripts do
the work:

- `ords-diag.sh` checks a server and says whether an upgrade can run now. It
  changes nothing.
- `ords-upgrade.sh` does the upgrade, and rolls back on its own if the new
  version does not come up healthy.

This page is the procedure. For what each script does step by step, its
options and its settings, see [REFERENCE.md](REFERENCE.md). To set up ORDS on
a new server, see [INSTALL.md](INSTALL.md).

> **Status.** Run for real on 2026-10-10: an EC2 server with a plain zip
> install, upgraded from ORDS 26.1.0 to 26.3.0 against RDS for Oracle, with
> the RDS master user as the admin user. The schema upgrade needed no extra
> grants. The diagnostic afterwards passed every check, including APEX. The
> config first had to move out of the ORDS directory
> ([section 2, step 5](#2-one-time-setup)).
>
> Before that, tested on Oracle Linux 9 with real systemd against Oracle 21c
> with APEX 26.1: zip installs from 24.4 to 26.2.3, RPM installs from 26.2.2
> to 26.2.3, automatic and manual rollback, and the diagnostic on healthy and
> broken servers.
>
> **Still untested against real AWS:** the script's own RDS snapshot
> (`RDS_INSTANCE_ID`; the 2026-10-10 run used a snapshot taken in the
> console instead), and the diagnostic's `describe-db-instances` check. Both
> have only run against a stub `aws`.

---

## Contents

1. [What you need on each server](#1-what-you-need-on-each-server)
2. [One-time setup](#2-one-time-setup)
3. [An upgrade, step by step](#3-an-upgrade-step-by-step)
4. [Several servers on one database](#4-several-servers-on-one-database)
5. [When an upgrade fails](#5-when-an-upgrade-fails)
6. [Rolling back later](#6-rolling-back-later)
7. [Servers without internet access](#7-servers-without-internet-access)
8. [Reading the diagnostic](#8-reading-the-diagnostic)
9. [Letting an agent advise you](#9-letting-an-agent-advise-you)
10. [Where things are on the server](#10-where-things-are-on-the-server)

---

## 1. What you need on each server

- ORDS running as a systemd service. The scripts handle three install
  layouts: a zip with a symlink, a plain unpacked zip, and Oracle's RPM.
- Root, through `sudo`.
- `bash`, `curl`, `unzip`, `tar`, `flock` and `runuser`. They are on any
  standard Oracle Linux, RHEL or Amazon Linux 2023 install. `ords-diag.sh` lists anything
  missing.
- The password of the database user that upgrades the ORDS schema. On RDS
  this is the master user.
- For the RDS snapshot: the aws CLI, with credentials that allow the three
  calls below. An instance profile on the server is the simplest way.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["rds:CreateDBSnapshot", "rds:DescribeDBSnapshots", "rds:DescribeDBInstances"],
    "Resource": [
      "arn:aws:rds:REGION:ACCOUNT:db:INSTANCE",
      "arn:aws:rds:REGION:ACCOUNT:snapshot:ords-upgrade-*"
    ]
  }]
}
```

`CreateDBSnapshot` needs both resources: the instance being copied and the
snapshot being created. The script names every snapshot `ords-upgrade-<time>`,
which is what the second line allows.

---

## 2. One-time setup

Do this once per server.

**1. Download the scripts onto the server.** Log in to the server and run:

```bash
mkdir -p ~/ords-tools && curl -fsSL https://github.com/juliusbsimon/ords-tools/archive/refs/tags/v1.2.0.tar.gz | tar xz -C ~/ords-tools --strip-components=1
cd ~/ords-tools
```

This puts the scripts in `~/ords-tools`. Both scripts load `ords-common.sh`
from their own folder, so keep the files together. To update later, run the
same command with a newer version number from the
[releases page](https://github.com/juliusbsimon/ords-tools/releases); it
replaces the scripts and leaves your settings in `/etc` alone.

If the server has no internet access, download the same file on a machine
that has, copy it over, and unpack it there:

```bash
curl -fsSLO https://github.com/juliusbsimon/ords-tools/archive/refs/tags/v1.2.0.tar.gz
scp -i ~/.ssh/server-key v1.2.0.tar.gz ec2-user@SERVER:
ssh -i ~/.ssh/server-key ec2-user@SERVER 'mkdir -p ~/ords-tools && tar xzf v1.2.0.tar.gz -C ~/ords-tools --strip-components=1'
```

`ssh` and `scp` cannot read a PuTTY key (`.ppk`). Convert it once:

```bash
sudo apt install -y putty-tools
puttygen ~/.ssh/server-key.ppk -O private-openssh -o ~/.ssh/server-key
chmod 600 ~/.ssh/server-key
```

**2. Create the settings file.** Blank settings are read from the systemd
unit, so most servers need only three lines.

```bash
sudo cp ords-upgrade.conf.example /etc/ords-upgrade.conf
sudo chmod 600 /etc/ords-upgrade.conf
sudo vi /etc/ords-upgrade.conf
```

```ini
ORDS_ADMIN_USER=admin                       # the RDS master user
ORDS_ADMIN_PWD_FILE=/root/.ords-admin-pwd
RDS_INSTANCE_ID=apexprod                    # the instance identifier, not the endpoint
```

**3. Store the password.** Put it on the first line of a file only root can
read. `read -rs` keeps it out of your shell history.

```bash
sudo bash -c 'read -rsp "Password: " p; echo; printf "%s\n" "$p" > /root/.ords-admin-pwd; chmod 600 /root/.ords-admin-pwd'
```

**4. Run the diagnostic.**

```bash
sudo ./ords-diag.sh
```

Fix every FAIL line before going further. [Section 8](#8-reading-the-diagnostic)
covers the common ones. A server that is set up correctly ends with
`Verdict: READY`, or `READY_WITH_WARNINGS` if you chose not to set
`RDS_INSTANCE_ID`.

**5. If the config is inside the ORDS directory, move it out.** The scripts
refuse to upgrade when the config lives in the folder that holds the ORDS
program files, such as `/opt/ords/config`. An upgrade replaces that folder,
so the config would be left behind with the old release. Move it once. ORDS
is down from the stop to the start, about a minute. These steps assume the
unit passes `--config /opt/ords/config`; check with `systemctl cat ords`.

```bash
sudo tar -C /opt/ords -czf /root/ords-config-before-move.tar.gz config
sudo systemctl stop ords
sudo mkdir -p /etc/ords && sudo mv /opt/ords/config /etc/ords/config
sudo grep -rl '>/opt/ords/config/' /etc/ords/config --include='*.xml' | xargs -r sudo sed -i 's|>/opt/ords/config/|>/etc/ords/config/|g'
sudo sed -i 's|--config /opt/ords/config|--config /etc/ords/config|' /etc/systemd/system/ords.service
sudo systemctl daemon-reload && sudo systemctl start ords
```

The `grep` line fixes settings that pointed inside the old folder, usually
`standalone.doc.root`. Then run `ords-diag.sh` again: `pool.<name>.status`
should be VALID and `install.upgrade_blockers` should pass.

To undo the move, run the same steps in reverse: stop ORDS, move the folder
back, swap the two paths in the `grep` and `sed` lines, then reload and start.

---

## 3. An upgrade, step by step

**1. Check every server first.** Run the diagnostic on each ORDS server that
uses the database.

```bash
sudo ./ords-diag.sh
```

Go on only when none of them says `NOT_READY`. A pool that is `INVALID` now
makes the upgrade roll back, because the upgrade judges the new version by the
same pool table.

**2. See the plan.** The dry run downloads the new release (about 200 MB),
checks that it runs on the server's Java, and prints what it would do. It does
not touch the service, the config or the database.

```bash
sudo ./ords-upgrade.sh --dry-run
```

Read the `installed` and `upgrade to` lines, and the `db backup` line. The
last one should name your RDS instance.

**3. Pick a window.** ORDS is down from the moment the service stops until the
new version passes its checks. That covers the schema upgrade and one ORDS
start. The RDS snapshot is taken before the service stops, so however long it
takes, ORDS keeps serving meanwhile.

**4. Upgrade the first server.**

```bash
sudo ./ords-upgrade.sh
```

It asks once for confirmation, then takes the RDS snapshot, backs up the
config, stops ORDS, switches to the new release, upgrades the ORDS schema,
starts ORDS and checks it. The last lines say `ORDS upgraded: <old> -> <new>`.

**5. Upgrade the other servers** that use the same database, straight away.
See [section 4](#4-several-servers-on-one-database).

**6. Check the result on each server.**

```bash
sudo ./ords-diag.sh
```

Look for `upgrade.last_run` as PASS, `pool.<name>.status` as VALID, and the
APEX check as PASS. Then open one of your APEX applications in a browser.

---

## 4. Several servers on one database

All ORDS servers on a database share one ORDS schema. The first server's
upgrade moves that schema forward for all of them.

- Upgrade them all in the same window, one after another.
- On the second and later servers, the schema step finds the schema already
  current. Only the binaries change.
- Leave `RDS_INSTANCE_ID` set on each. Each run takes its own snapshot,
  which costs time but no downtime.
- Keep the `ORDS_PUBLIC_USER` password the same in every server's wallet. The
  schema step resets that user's database password to the value in the
  wallet of the server being upgraded. If the wallets differ, the last server
  upgraded wins and the others' pools go `INVALID`.

The diagnostic cannot see the other servers, so keep the list yourself.

---

## 5. When an upgrade fails

The script rolls back on its own if anything fails after ORDS stops: the old
binaries and config come back, and ORDS starts again. You will see
`The upgrade failed - putting ORDS <old> back`.

**1. Read the log** the script names at the end:
`/var/backups/ords-upgrade/<time>/upgrade.log`.

**2. Run the diagnostic.** It reports the failed run under `upgrade.last_run`,
and says whether the database was touched:

- *"It failed before the schema step changed anything"*: the database is as
  it was. Fix the cause and run the upgrade again.
- *"The ORDS schema may already be on <new>"*: the old ORDS is now running
  against a newer schema. In testing, ORDS 24.4 served APEX normally against
  a 26.2.3 schema, but that is one combination. Fix the cause and finish the
  upgrade soon.

**Common causes:**

| What the log says | Cause | Fix |
|---|---|---|
| `ORDS could not log in as ...` | Wrong admin password, or the database is unreachable | Fix the password file; check `pool.<name>.network` in the diagnostic |
| `ORA-01031: insufficient privileges` | The RDS master user lacks a grant ORDS needs | Apply the grants in AWS's page on setting up ORDS for RDS for Oracle |
| `not every pool can reach its database` | A pool is `INVALID` after the new version starts | The diagnostic shows the ORA- error and a hint |
| `needs Java N or later` | The new release needs a newer Java | Install that JDK, point the unit's `JAVA_HOME` at it, rerun |

---

## 6. Rolling back later

If a problem shows up after a successful upgrade:

```bash
sudo ./ords-upgrade.sh --rollback
```

This puts back the previous release and the config from before the upgrade.
Config changes made since the upgrade are set aside next to the config
directory, not deleted. **The database schema stays on the new version.**

Only the RDS snapshot takes the schema back, and it takes everything else in
the database back too. Every row written since the snapshot is lost. Use it
only when the problem is found straight away:

1. Restore the snapshot. RDS always restores into a **new** instance:

   ```bash
   aws rds restore-db-instance-from-db-snapshot \
       --db-instance-identifier apexprod-restored \
       --db-snapshot-identifier ords-upgrade-20261001-2100 \
       --option-group-name YOUR-APEX-OPTION-GROUP \
       --db-subnet-group-name YOUR-SUBNET-GROUP \
       --vpc-security-group-ids sg-XXXXXXXX
   ```

   Copy these from the original instance. RDS's defaults differ: without the
   option group the new instance has no APEX, and without the security group
   the ORDS servers cannot reach it.

2. Point each pool at the new endpoint, as the ORDS user:

   ```bash
   sudo -u oracle /opt/oracle/ords/bin/ords --config /etc/ords/config \
       config set db.hostname apexprod-restored.abc123.eu-central-1.rds.amazonaws.com
   ```

   For any pool other than the default, put `--db-pool NAME` before `set`:
   `... config --db-pool NAME set db.hostname ...`.

3. Run `--rollback` on every server, then `ords-diag.sh` on each.

The snapshot ID is in the upgrade's output, and in `last_run` in the
diagnostic.

---

## 7. Servers without internet access

Download the zip on a machine that has access, copy it over, and name it:

```bash
curl -LO https://download.oracle.com/otn_software/java/ords/ords-latest.zip
scp ords-latest.zip ords-host:
sudo ./ords-upgrade.sh --zip ords-latest.zip --dry-run
sudo ./ords-upgrade.sh --zip ords-latest.zip
```

`--sha256 HEX` refuses a zip whose checksum does not match. To install a
particular release rather than the latest, use `--version` with the build
number that `ords --version` prints, for example `26.2.1.r1901402`. RPM
installs use the package version, for example `26.2.3`.

---

## 8. Reading the diagnostic

Every line has a status and a check ID:

```text
FAIL  pool.default.status            INVALID at the last start: ORDS cannot use this database
        ORDS was unable to make a connection to the database. ... (ORA-01017)
        Hint: Wrong username or password. ...
```

The last line is the verdict. `NOT_READY` means at least one FAIL, and the
exit status is 2. `--json` gives the same checks in a form a script or agent
can read.

The FAIL lines you are most likely to meet:

| Check | What it means | What to do |
|---|---|---|
| `pool.<name>.status` | ORDS cannot use that pool's database | Follow the ORA- hint. The usual ones are a wrong password, a locked account, or a network block |
| `pool.<name>.network` | The database host does not resolve or does not accept connections | On RDS, check the security group allows this server on port 1521 |
| `service.state` | ORDS is not running | `journalctl -u ords` shows why. The upgrade cannot health-check a stopped service |
| `config.ownership` | The service user cannot read part of its config | Usually from running `ords` as root. `chown -R` the config to the service user |
| `install.upgrade_blockers` | The upgrade would refuse this layout | The detail gives the exact change, for example moving APEX images out of the ORDS directory |
| `upgrade.db_snapshot` | The snapshot would fail | Install the aws CLI, fix its permissions, or correct `RDS_INSTANCE_ID` |
| `upgrade.last_run` | The last upgrade stopped part-way | Read its `upgrade.log` before running again |

---

## 9. Letting an agent advise you

An agent, such as Claude Code on the server, can check the server and advise
you on the upgrade. It needs to run commands there. Give it these rules along
with your question:

```text
You are advising me on upgrading ORDS on this server with the scripts in
~/ords-tools. Read ~/ords-tools/README.md and ~/ords-tools/docs/GUIDE.md first.

You may run, without asking:
  sudo ./ords-diag.sh --json
  sudo ./ords-upgrade.sh --dry-run    (only if the verdict is not NOT_READY)
  journalctl -u ords, and files under /var/backups/ords-upgrade and /var/log/ords

Do not run ords-upgrade.sh without --dry-run, or with --rollback. Those stop
ORDS and change the database. Tell me what you recommend and I will run it.

Other ORDS servers use the same database: <list them, or say "none">.
```

A good answer names the FAIL and WARN lines by check ID, says what to fix
and in what order, and ends with the command to run next.

---

## 10. Where things are on the server

| Path | What |
|---|---|
| `/etc/ords-upgrade.conf` | Settings |
| `/var/backups/ords-upgrade/<time>/` | One directory per upgrade: `upgrade.log`, the config backup, the `ords install` logs, and a state file |
| `/var/backups/ords-upgrade/last` | Link to the last successful upgrade, which `--rollback` undoes |
| `/var/backups/ords-upgrade/downloads/` | Downloaded zips, reused while Oracle's copy is unchanged |
| `<ORDS_HOME>/../ords-versions/` | Unpacked releases (zip installs). The current one, the one before it, and up to `KEEP_VERSIONS` in total |
| `<config>.replaced-<time>` | Config directories set aside by a rollback. Delete them once you no longer need them |
