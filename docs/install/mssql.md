# SQL Server 2022 Developer on Ubuntu 22.04 (`vm-apps`)

Installed 2026-10-12 from the Microsoft package repository. Passwords are shown as `<...>`.

## Result

| Item | Value |
|------|-------|
| Version | Microsoft SQL Server 2022 (RTM-CU27) 16.0.4295.3, Developer Edition (64-bit) |
| Host | `vm-apps` 192.168.56.20, port 1433 |
| Data / log / backup | `/srv/mssql/data`, `/srv/mssql/log`, `/srv/mssql/backup` |
| Memory | process limit 2048 MB, `max server memory` 1536 MB |
| SQL Server Agent | enabled |
| Database | `inventory` |
| Tools | `mssql-tools18` 18.7.1.1 (`sqlcmd`) |

## 1. Host `vm-apps`

Created by [`scripts/lab/create-vms.ps1`](../../scripts/lab/create-vms.ps1): Ubuntu 22.04.5 Server,
5 GB RAM, 2 vCPU, 40 GB disk, NIC1 NAT, NIC2 host-only `enp0s8` 192.168.56.20/24 static.
OpenSSH server selected in the installer; no snaps.

```bash
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv   # installer only used 19 GB of the 40 GB
sudo timedatectl set-timezone Asia/Ho_Chi_Minh            # same timezone as vm-oracle for log correlation
curl -fsSL https://get.docker.com | sudo sh               # Docker Engine 29.9.0 (for the MySQL replica)
sudo usermod -aG docker son
```

The `ubuntu-vg/ubuntu-lv` volume grew from 19 GB to 38 GB. Ubuntu 22.04 is kept on purpose
(`do-release-upgrade` to 24.04 is not run): the SQL Server repository used is the 22.04 one.

## 2. Install

```bash
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg
curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list | sudo tee /etc/apt/sources.list.d/mssql-server-2022.list
curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/prod.list | sudo tee /etc/apt/sources.list.d/mssql-prod.list
sudo apt-get update
sudo apt-get install -y mssql-server
sudo /opt/mssql/bin/mssql-conf setup        # edition 2 = Developer, accept licence, SA password
sudo ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev
echo 'export PATH=$PATH:/opt/mssql-tools18/bin' >> ~/.bashrc
```

Developer edition: free, full Enterprise feature set, not licensed for production.
`Failed to open password policy registry path` during setup is normal on Linux.

## 3. Configuration

```bash
sudo mkdir -p /srv/mssql/data /srv/mssql/log /srv/mssql/backup
sudo chown -R mssql:mssql /srv/mssql
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultdatadir   /srv/mssql/data
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultlogdir    /srv/mssql/log
sudo /opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir /srv/mssql/backup
sudo /opt/mssql/bin/mssql-conf set memory.memorylimitmb 2048
sudo /opt/mssql/bin/mssql-conf set sqlagent.enabled true
sudo systemctl restart mssql-server

sqlcmd -S localhost -U sa -C -Q "EXEC sp_configure 'show advanced options',1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)',1536; RECONFIGURE;"
```

| Setting | Reason |
|---------|--------|
| Separate data / log / backup folders | Standard layout; makes the later backup jobs and file growth easy to follow |
| `memory.memorylimitmb 2048` | Default is 80% of RAM (~4 GB), which would starve MySQL on the same VM |
| `max server memory 1536` | Buffer pool cap below the process limit, leaving room for the engine itself |
| SQL Server Agent | Runs the full / differential / log backup jobs in phase 3 |
| `sqlcmd -C` | Trust the self-signed certificate SQL Server on Linux generates |

Verified:

```
$ sqlcmd ... -W -h -1 -Q "SELECT SERVERPROPERTY('Edition'); ... value_in_use ... 'max server memory (MB)'"
Developer Edition (64-bit)
16.0.4295.3
/srv/mssql/data/
/srv/mssql/log/
1536
$ systemctl status mssql-server → active (running)
```

## 4. Accounts

SQL Server has two levels: a **login** (server, authentication) and a **user** (database, authorisation).
Permissions are granted to database roles, never to users directly.

To avoid multi-line paste problems each statement was run with `sqlcmd -Q`, with the SA password
read once into `SQLCMDPASSWORD` (`read -s`, not echoed, not in shell history) and unset afterwards.

```sql
CREATE DATABASE inventory;
CREATE LOGIN app_rw    WITH PASSWORD = '<PW>';
CREATE LOGIN report_ro WITH PASSWORD = '<PW>';
CREATE LOGIN dba_admin WITH PASSWORD = '<PW>';
ALTER SERVER ROLE sysadmin ADD MEMBER dba_admin;

USE inventory;
CREATE ROLE role_app_rw;
CREATE ROLE role_report_ro;
ALTER ROLE db_datareader ADD MEMBER role_app_rw;
ALTER ROLE db_datawriter ADD MEMBER role_app_rw;
GRANT EXECUTE ON SCHEMA::dbo TO role_app_rw;
ALTER ROLE db_datareader ADD MEMBER role_report_ro;
CREATE USER app_rw    FOR LOGIN app_rw;    ALTER ROLE role_app_rw    ADD MEMBER app_rw;
CREATE USER report_ro FOR LOGIN report_ro; ALTER ROLE role_report_ro ADD MEMBER report_ro;
```

Verified role membership in `inventory`:

```
member          role
role_app_rw     db_datareader
role_report_ro  db_datareader
role_app_rw     db_datawriter
app_rw          role_app_rw
report_ro       role_report_ro
```

Logins `app_rw`, `report_ro`, `dba_admin` exist. DBeaver from Windows (`192.168.56.20:1433`,
SQL Server Authentication, `dba_admin`) connects. `dba_admin` (sysadmin) is used only for administration.

## 5. Restart test

After `sudo reboot` of `vm-apps`: `systemctl is-active mssql-server` → `active`, DBeaver reconnects.

## Troubleshooting

- In interactive `sqlcmd`, `GO` must be alone on its line; `CREATE DATABASE inventory; GO` gives
  `Msg 102 Incorrect syntax near 'GO'`. Multi-line pastes into the SSH terminal also dropped lines,
  hence the one-statement-per-`sqlcmd -Q` approach above.
- `SELECT @@VERSION` returns a long padded column that scrolls everything off screen; use
  `sqlcmd -W -h -1` and `SERVERPROPERTY(...)`.

## Known lab limitations

- No Always On availability group (needs a second node); covered by full/diff/log backups and
  point-in-time restore drills in phase 3.
- SQL Server and MySQL share one 5 GB VM.
