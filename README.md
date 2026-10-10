# ORDS tools

Scripts for running Oracle REST Data Services (ORDS) on a Linux server under
systemd, outside containers:

| Script | What it does |
|---|---|
| `ords-install.sh` | Installs ORDS on a new server, with its systemd service, Java and a dedicated user, ready for the other two. |
| `ords-diag.sh` | Checks the server and says whether an upgrade can run now. Changes nothing. |
| `ords-upgrade.sh` | Upgrades ORDS and its database schema. Rolls back on its own if the new version does not come up healthy. |

The upgrade and the diagnostic also work on servers set up by hand: a zip
install (plain or behind a symlink) or Oracle's RPM. The database can be on
RDS for Oracle or self-managed.

## Download

On the ORDS server:

```bash
mkdir -p ~/ords-tools && curl -fsSL https://github.com/juliusbsimon/ords-tools/archive/refs/tags/v1.1.0.tar.gz | tar xz -C ~/ords-tools --strip-components=1
cd ~/ords-tools
```

No git, SSH key or copying from another machine needed. To update, run the
same command with the newest version from the
[releases page](https://github.com/juliusbsimon/ords-tools/releases). Your
settings live in `/etc`, so they are kept.

## Install ORDS on a new server

```bash
sudo bash -c 'read -rsp "Password: " p; echo; printf "%s\n" "$p" > /root/.ords-admin-pwd; chmod 600 /root/.ords-admin-pwd'
sudo dnf install -y java-21-openjdk-headless
sudo ./ords-install.sh --db-host mydb.abc123.us-east-2.rds.amazonaws.com --db-service ORCL \
    --admin-user admin --admin-pwd-file /root/.ords-admin-pwd --dry-run
```

The dry run logs in to the database and prints the plan. Run it again without
`--dry-run` to install. When other ORDS servers already use the database, add
`--proxy-pwd-file` with their `ORDS_PUBLIC_USER` password.
[docs/INSTALL.md](docs/INSTALL.md) has the details.

## Upgrade ORDS

**1. Settings.** Most servers need three lines. Everything else is read from
the systemd unit.

```bash
sudo cp ords-upgrade.conf.example /etc/ords-upgrade.conf
sudo chmod 600 /etc/ords-upgrade.conf
sudo vi /etc/ords-upgrade.conf
```

```ini
ORDS_ADMIN_USER=admin                     # the RDS master user, or SYS on a self-managed database
ORDS_ADMIN_PWD_FILE=/root/.ords-admin-pwd
RDS_INSTANCE_ID=mydb                      # the instance identifier; the script snapshots it first
```

**2. The admin password,** in a file only root can read:

```bash
sudo bash -c 'read -rsp "Password: " p; echo; printf "%s\n" "$p" > /root/.ords-admin-pwd; chmod 600 /root/.ords-admin-pwd'
```

**3. Check the server, then see the plan.** Neither changes anything.

```bash
sudo ./ords-diag.sh
sudo ./ords-upgrade.sh --dry-run
```

Fix any FAIL line from the diagnostic first. The dry run downloads the new
release, checks it runs on the server's Java, and prints what it would do.

**4. Upgrade:**

```bash
sudo ./ords-upgrade.sh
```

If other ORDS servers use the same database, upgrade them straight after:
the database's ORDS schema moves forward for all of them at once.

**To undo it:** `sudo ./ords-upgrade.sh --rollback` puts back the previous
release and config. The database schema stays on the new version; only a
database snapshot takes that back.

## More

- [docs/INSTALL.md](docs/INSTALL.md) covers installing: the first server
  and the ones after it, APEX, every option, and failures.
- [docs/GUIDE.md](docs/GUIDE.md) is the full procedure: setup, an upgrade
  window, several servers on one database, failures, rollback, servers
  without internet access, reading the diagnostic, and letting an agent
  advise you.
- [docs/REFERENCE.md](docs/REFERENCE.md) covers what each script does step
  by step, every option and setting, and how they were tested.

## Status

The installer is tested on Oracle Linux 9 containers with real systemd,
against Oracle 21c with APEX 26.1. It has not yet been run against RDS.

The upgrade was used for real on 2026-10-10: ORDS 26.1.0 to 26.3.0 on an EC2
server against RDS for Oracle. Before that, tested on Oracle Linux 9 with
real systemd against Oracle 21c and APEX 26.1, including automatic and
manual rollback. The script's own RDS snapshot has so far only been tested
against a stub `aws`. Details are in the reference.

## Licence

MIT. See [LICENSE](LICENSE).
