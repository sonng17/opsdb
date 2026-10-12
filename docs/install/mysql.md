# MySQL 8.4 LTS, primary + GTID replica (`vm-apps`)

Installed 2026-10-12. Primary is a native install from the official MySQL APT repository;
the replica is the official `mysql:8.4` Docker image on the same VM. Passwords are shown as `<...>`.

## Result

| Item | Primary | Replica |
|------|---------|---------|
| Version | 8.4.11 (MySQL Community Server) | `mysql:8.4` image |
| Runs as | systemd `mysql.service` | container `mysql-replica`, `--restart unless-stopped` |
| Port on `vm-apps` | 3306 | 3307 → 3306 |
| `server_id` | 1 | 2 |
| GTID | ON | ON |
| Buffer pool | 1 GB | 256 MB (container memory limit 512 MB) |
| Writes | yes | blocked: `super_read_only = ON` |
| Replication | — | `Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`, `Seconds_Behind_Source: 0` |

Host preparation for `vm-apps` (disk, timezone, Docker) is in [mssql.md](mssql.md#1-host-vm-apps).

## 1. Primary install

Ubuntu 22.04 only ships MySQL 8.0, so the MySQL APT repository is added first.

```bash
F=$(curl -s https://dev.mysql.com/downloads/repo/apt/ | grep -o 'mysql-apt-config_[0-9.]*-[0-9]*_all.deb' | head -1)
wget https://dev.mysql.com/get/$F          # mysql-apt-config_0.8.40-1_all.deb
sudo dpkg -i $F                            # MySQL Server & Cluster → mysql-8.4-lts → Ok
sudo apt-get update
sudo apt-get install -y mysql-server       # root password, "Use Strong Password Encryption"
sudo mysql_secure_installation
```

`mysql_secure_installation`: VALIDATE PASSWORD component on, policy MEDIUM (length ≥ 8, upper,
lower, digit, special character); anonymous users removed; remote root login disabled; test database removed.

## 2. Primary configuration

Project settings live in their own file so package upgrades never overwrite them and the
whole configuration is reviewable in one place:

```ini
# /etc/mysql/mysql.conf.d/opsdb.cnf
[mysqld]
server_id                = 1
bind_address             = 0.0.0.0
log_bin                  = mysql-bin
gtid_mode                = ON
enforce_gtid_consistency = ON
innodb_buffer_pool_size  = 1G
slow_query_log           = ON
slow_query_log_file      = /var/log/mysql/slow.log
long_query_time          = 1
```

| Parameter | Reason |
|-----------|--------|
| `server_id = 1` | Unique per server in a replication topology (replica = 2) |
| `bind_address = 0.0.0.0` | Accept DBeaver from Windows and the replica container |
| `log_bin` | Binary log: required for replication and point-in-time recovery (phase 3) |
| `gtid_mode`, `enforce_gtid_consistency` | GTID replication: replica tracks its own position, failover is simpler |
| `innodb_buffer_pool_size = 1G` | RAM budget for `vm-apps` (SQL Server 2 GB, replica 512 MB) |
| slow query log, 1 s | Input for the tuning work in phase 6 |

Verified after `systemctl restart mysql`:

```
@@version 8.4.11 | @@server_id 1 | @@gtid_mode ON | @@log_bin 1 | bp_mb 1024 | @@slow_query_log 1 | @@bind_address 0.0.0.0
```

## 3. Replica (Docker)

```bash
docker run -d --name mysql-replica --restart unless-stopped --memory 512m \
  -p 3307:3306 --add-host=host.docker.internal:host-gateway \
  -e MYSQL_ROOT_PASSWORD='<PW>' -v mysql-replica-data:/var/lib/mysql \
  mysql:8.4 --server-id=2 --gtid-mode=ON --enforce-gtid-consistency=ON --innodb-buffer-pool-size=256M
```

`host.docker.internal` resolves to the Docker host, i.e. the primary. Data is on the named
volume `mysql-replica-data`, so recreating the container keeps it.

On the **primary**:

```sql
RESET BINARY LOGS AND GTIDS;   -- only acceptable because the primary is still empty
CREATE USER 'repl'@'172.17.%' IDENTIFIED BY '<PW>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'172.17.%';
```

`172.17.%` restricts the replication account to the Docker bridge network. On a primary that
already holds data the replica must be seeded from a backup instead (practised in incident drill 4).

On the **replica**:

```sql
RESET BINARY LOGS AND GTIDS;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='host.docker.internal', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='<PW>',
  SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SET PERSIST super_read_only = ON;
```

- `SOURCE_AUTO_POSITION=1`: GTID auto-positioning, no binlog file/position to track.
- `GET_SOURCE_PUBLIC_KEY=1`: needed for `caching_sha2_password` without TLS.
- `super_read_only` is set with `SET PERSIST` after start-up, not as a `docker run` flag,
  because the flag would also block the image's own root-password initialisation.
- `CHANGE REPLICATION SOURCE` returned 2 warnings: credentials stored in the replica's
  metadata tables and the connection not forced to SSL. Accepted for the lab (see limitations).

Verified:

```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
Last_IO_Error:
Last_SQL_Error:
```

## 4. Accounts

Run on the primary; privileges are attached to roles.

```sql
CREATE DATABASE orders CHARACTER SET utf8mb4;
CREATE ROLE 'orders_rw', 'orders_ro';
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON orders.* TO 'orders_rw';
GRANT SELECT ON orders.* TO 'orders_ro';
CREATE USER 'app_rw'@'192.168.56.%'    IDENTIFIED BY '<PW>' DEFAULT ROLE 'orders_rw';
CREATE USER 'report_ro'@'192.168.56.%' IDENTIFIED BY '<PW>' DEFAULT ROLE 'orders_ro';
CREATE USER 'dba_admin'@'192.168.56.%' IDENTIFIED BY '<PW>';
GRANT ALL ON *.* TO 'dba_admin'@'192.168.56.%' WITH GRANT OPTION;
```

`192.168.56.%` limits logins to the lab network.

## 5. Evidence

**Replication carries real changes.** Nothing was created on the replica, yet:

```
$ docker exec -it mysql-replica mysql -uroot -p -e "SHOW DATABASES; SELECT user, host FROM mysql.user WHERE user IN ('app_rw','report_ro','dba_admin');"
information_schema | mysql | orders | performance_schema | sys
app_rw    192.168.56.%
dba_admin 192.168.56.%
report_ro 192.168.56.%
```

**The replica refuses writes, even from root:**

```
$ docker exec -it mysql-replica mysql -uroot -p -e "CREATE TABLE orders.t(x int);"
ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement
```

Same result from DBeaver on Windows (`192.168.56.20:3307`, `dba_admin`): `SQL Error [1290]`.
The primary (`3306`) accepts `dba_admin` from DBeaver (driver property `allowPublicKeyRetrieval=true`).

**Survives a reboot.** After `sudo reboot` (`uptime -s` 14:03), with no manual action:

```
systemctl is-active mssql-server mysql docker → active active active
docker ps → mysql-replica  Up
SHOW REPLICA STATUS → Yes / Yes / 0
```

## Troubleshooting

- `CREATE USER 'repl'...` with a password lacking a special character failed with `ERROR 1819 Your password does not satisfy the current
  policy requirements`: MEDIUM policy needs a special character. The following `GRANT` then failed
  with `ERROR 1410 You are not allowed to create a user with GRANT` because the user did not exist.
- `docker exec ... | grep` hides the `Enter password:` prompt, so the command looks hung; it is
  waiting for input.
- A forgotten replica root password can be read back with
  `docker inspect mysql-replica --format '{{range .Config.Env}}{{println .}}{{end}}'`, which is
  also why passing secrets in environment variables is weak (see limitations).

## Known lab limitations

- Replica and primary are on the same VM: it demonstrates replication, failover and rebuild,
  not protection against host failure.
- Asynchronous replication: a primary crash can lose transactions not yet received by the replica.
- Replication traffic is not TLS-encrypted; replication credentials are stored in the replica's
  metadata tables.
- `MYSQL_ROOT_PASSWORD` is passed as an environment variable and is readable via `docker inspect`;
  production would use Docker secrets or `MYSQL_ROOT_PASSWORD_FILE`.
