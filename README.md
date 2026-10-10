# ORDS tools

Scripts for running Oracle REST Data Services (ORDS) on a Linux server under
systemd, outside containers:

| Script | What it does |
|---|---|
| `ords-diag.sh` | Checks the server and says whether an upgrade can run now. Changes nothing. |
| `ords-upgrade.sh` | Upgrades ORDS and its database schema. Rolls back on its own if the new version does not come up healthy. |

Both work with a zip install (plain or behind a symlink) or Oracle's RPM, and
with the database on RDS for Oracle or self-managed. An installer for new
servers is planned.

## Download

On the ORDS server:

```bash
mkdir -p ~/ords-tools && curl -fsSL https://github.com/juliusbsimon/ords-tools/archive/refs/tags/v1.0.0.tar.gz | tar xz -C ~/ords-tools --strip-components=1
cd ~/ords-tools
```

No git, SSH key or copying from another machine needed. To update, run the
same command with the newest version from the
[releases page](https://github.com/juliusbsimon/ords-tools/releases). Your
settings live in `/etc`, so they are kept.

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

- [docs/GUIDE.md](docs/GUIDE.md) is the full procedure: setup, an upgrade
  window, several servers on one database, failures, rollback, servers
  without internet access, reading the diagnostic, and letting an agent
  advise you.
- [docs/REFERENCE.md](docs/REFERENCE.md) covers what each script does step
  by step, every option and setting, and how they were tested.

## Status

Used for a real upgrade on 2026-10-10: ORDS 26.1.0 to 26.3.0 on an EC2
server against RDS for Oracle. Before that, tested on Oracle Linux 9 with
real systemd against Oracle 21c and APEX 26.1, including automatic and
manual rollback. The script's own RDS snapshot has so far only been tested
against a stub `aws`. Details are in the reference.

## Licence

MIT. See [LICENSE](LICENSE).
