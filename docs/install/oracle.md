# Oracle Database 19c on Oracle Linux 8.10 (`vm-oracle`)

Installed 2026-10-12. Software-only silent install, CDB `OPSCDB` with one PDB `LEDGER`
created by DBCA in silent mode, no GUI anywhere. Every step below was run and verified
in the lab. Passwords are shown as `<...>` placeholders.

## Result

| Item | Value |
|------|-------|
| OS | Oracle Linux Server 8.10, kernel UEK 5.15.0-206 |
| Database | Oracle Database 19c Enterprise Edition 19.3.0.0.0 |
| Container | CDB `OPSCDB`, PDB `LEDGER` (READ WRITE, state saved) |
| Character set | AL32UTF8 / AL16UTF16 |
| Memory | `sga_target` 1200M, `pga_aggregate_target` 400M |
| Log mode | ARCHIVELOG, archives to FRA |
| FRA | `/u03/fra`, `db_recovery_file_dest_size` 15G |
| Listener | `vm-oracle.lab:1521`, services `OPSCDB`, `ledger` |
| Autostart | systemd unit `oracle-opscdb.service` (verified across reboot) |
| Time sync | chrony, timezone Asia/Ho_Chi_Minh |

## 1. Virtual machine

Created by [`scripts/lab/create-vms.ps1`](../../scripts/lab/create-vms.ps1).

| Setting | Value | Why |
|---------|-------|-----|
| RAM | 4 GB | Budget: 16 GB laptop, Windows uses ~3.9 GB, `vm-apps` needs 5 GB |
| vCPU | 2 (plan was 3) | See Troubleshooting 1 |
| Disk `os.vdi` | 30 GB, LVM: `/` 26G, swap 3G, `/boot` 1G | OS + Oracle home under `/u01` |
| Disk `data.vdi` | 20 GB XFS on `/u02` | Datafiles and online redo on their own disk |
| Disk `fra.vdi` | 16 GB XFS on `/u03` | Archivelogs/backups separated from data, so a full FRA cannot fill the datafile disk |
| NIC1 | NAT, `enp0s3` 10.0.2.15 | Internet for `dnf` |
| NIC2 | Host-only, `enp0s8` 192.168.56.10/24 static | DBeaver/SSH from Windows, traffic to `vm-apps` |
| Graphics | VMSVGA, 64 MB | Default VBoxVGA 8 MB froze the installer |

OS install choices: Minimal Install, kdump off, only the 30 GB disk selected, hostname `vm-oracle.lab`.
Installed in *basic graphics mode* (boot menu > Troubleshooting).

## 2. OS preparation (root)

```bash
echo "192.168.56.10 vm-oracle.lab vm-oracle" >> /etc/hosts
dnf install -y oracle-database-preinstall-19c unzip    # user oracle, groups, sysctl, limits, packages
passwd oracle

mkfs.xfs /dev/sdb
mkfs.xfs /dev/sdc
mkdir -p /u02 /u03
echo "UUID=$(blkid -s UUID -o value /dev/sdb) /u02 xfs defaults 0 0" >> /etc/fstab
echo "UUID=$(blkid -s UUID -o value /dev/sdc) /u03 xfs defaults 0 0" >> /etc/fstab
mount -a && systemctl daemon-reload

mkdir -p /u01/app/oracle/product/19.0.0/dbhome_1 /u01/app/oraInventory /u01/stage /u02/oradata /u03/fra
chown -R oracle:oinstall /u01 /u02 /u03
chmod -R 775 /u01 /u02 /u03

firewall-cmd --permanent --add-port=1521/tcp
firewall-cmd --reload
```

- Disks are mounted by UUID so a change in device order (`sdb`/`sdc`) cannot swap `/u02` and `/u03`.
- Verified: `id oracle` shows `oinstall, dba, oper, backupdba, dgdba, kmdba, racdba`;
  `oracle-database-preinstall-19c-1.0-4.el8`.
- Swap is 3 GB, below Oracle's recommendation (= RAM). The installer reports it as an optional
  prerequisite (INS-13014); accepted for the lab.

A VirtualBox snapshot `os-ready` was taken here.

## 3. Software install (oracle)

```bash
# ~/.bash_profile
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=$ORACLE_BASE/product/19.0.0/dbhome_1
export ORACLE_SID=OPSCDB
export PATH=$ORACLE_HOME/bin:$PATH
export CV_ASSUME_DISTID=OEL7.8
```

`CV_ASSUME_DISTID=OEL7.8` is required: the 19.3 installer predates OL8 and otherwise fails
with `[INS-08101] supportedOSCheck`.

19c ships as an image, so the zip is extracted straight into `ORACLE_HOME`:

```bash
cd $ORACLE_HOME
unzip -q /u01/stage/LINUX.X64_193000_db_home.zip

./runInstaller -silent -ignorePrereqFailure -waitforcompletion \
  oracle.install.option=INSTALL_DB_SWONLY \
  UNIX_GROUP_NAME=oinstall INVENTORY_LOCATION=/u01/app/oraInventory \
  ORACLE_HOME=$ORACLE_HOME ORACLE_BASE=$ORACLE_BASE \
  oracle.install.db.InstallEdition=EE \
  oracle.install.db.OSDBA_GROUP=dba oracle.install.db.OSOPER_GROUP=oper \
  oracle.install.db.OSBACKUPDBA_GROUP=backupdba oracle.install.db.OSDGDBA_GROUP=dgdba \
  oracle.install.db.OSKMDBA_GROUP=kmdba oracle.install.db.OSRACDBA_GROUP=racdba \
  DECLINE_SECURITY_UPDATES=true
```

Result: `Successfully Setup Software with warning(s)` (INS-13014, swap). Then as **root**:

```bash
/u01/app/oraInventory/orainstRoot.sh
/u01/app/oracle/product/19.0.0/dbhome_1/root.sh
```

Note: both scripts were first run by mistake as `oracle` (`This script must be executed as root`)
and then re-run as root; `root.sh` is safe to re-run.

## 4. Listener and database

```bash
netca -silent -responseFile $ORACLE_HOME/assistants/netca/netca.rsp   # LISTENER on vm-oracle.lab:1521

nohup dbca -silent -createDatabase -templateName General_Purpose.dbc \
  -gdbName OPSCDB -sid OPSCDB -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \
  -createAsContainerDatabase true -numberOfPDBs 1 -pdbName LEDGER \
  -sysPassword <PW> -systemPassword <PW> -pdbAdminPassword <PW> \
  -storageType FS -datafileDestination /u02/oradata \
  -recoveryAreaDestination /u03/fra -recoveryAreaSize 15360 \
  -memoryMgmtType AUTO_SGA -totalMemory 1600 -redoLogFileSize 200 \
  -emConfiguration NONE -sampleSchema false > ~/dbca.log 2>&1 &
```

| Parameter | Reason |
|-----------|--------|
| Listener created before DBCA | Instance registers its services automatically |
| `nohup ... &` | DBCA runs ~30 min; survives an SSH disconnect |
| `AL32UTF8` | Vietnamese and any other Unicode text |
| CDB + 1 PDB | Multitenant is the 19c standard; app users live only in the PDB |
| `-recoveryAreaSize 15360` | FRA capped at 15 GB on a 16 GB disk |
| `-totalMemory 1600` | Fits a 4 GB VM; tuned afterwards (section 5) |
| `-redoLogFileSize 200` | Fewer log switches under simulator load |
| `-emConfiguration NONE`, no samples | Save RAM and disk |

`~/dbca.log` ended with `100% complete` / `Database creation complete`.

## 5. Memory and ARCHIVELOG

```sql
-- sqlplus / as sysdba
ALTER SYSTEM SET sga_max_size=1200M SCOPE=SPFILE;
ALTER SYSTEM SET sga_target=1200M SCOPE=SPFILE;
ALTER SYSTEM SET pga_aggregate_target=400M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE LEDGER OPEN;
ALTER PLUGGABLE DATABASE LEDGER SAVE STATE;   -- PDB reopens on every startup
ALTER SYSTEM SWITCH LOGFILE;                  -- force a first archivelog
```

ARCHIVELOG is required for online RMAN backups and point-in-time recovery (phase 3).

Verified:

```
LOG_MODE      ARCHIVELOG
Automatic archival   Enabled
Archive destination  USE_DB_RECOVERY_FILE_DEST
sga_target 1200M | pga_aggregate_target 400M
db_recovery_file_dest /u03/fra | db_recovery_file_dest_size 15G
/u03/fra/OPSCDB/archivelog/2026_10_12/o1_mf_1_7_....arc
lsnrctl: Service "OPSCDB" READY, Service "ledger" READY
```

## 6. Start on boot (root)

`/etc/oratab`: `OPSCDB:/u01/app/oracle/product/19.0.0/dbhome_1:Y`

Wrapper scripts in `/usr/local/bin` (see Troubleshooting 4 for why not call `dbstart` directly):

```bash
cat > /usr/local/bin/oracle-db-start <<'EOF'
#!/bin/bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
exec $ORACLE_HOME/bin/dbstart $ORACLE_HOME
EOF
cat > /usr/local/bin/oracle-db-stop <<'EOF'
#!/bin/bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
exec $ORACLE_HOME/bin/dbshut $ORACLE_HOME
EOF
chmod 755 /usr/local/bin/oracle-db-start /usr/local/bin/oracle-db-stop
restorecon -v /usr/local/bin/oracle-db-*
```

`/etc/systemd/system/oracle-opscdb.service`:

```ini
[Unit]
Description=Oracle Database OPSCDB and listener
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=oracle
Group=oinstall
ExecStart=/usr/local/bin/oracle-db-start
ExecStop=/usr/local/bin/oracle-db-stop
TimeoutSec=600

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable oracle-opscdb
```

Verified after `reboot`: unit `active (exited)`, `ARCHIVELOG`, `LEDGER READ WRITE`,
`Service "ledger" has 1 instance(s)`. Snapshot `oracle-ready` taken.

## 7. Time sync

Minimal Install has no NTP client (`NTP service: n/a`); the clock had drifted ~40 minutes.

```bash
dnf install -y chrony
sed -i 's/^makestep.*/makestep 1.0 -1/' /etc/chrony.conf   # always step if off by >1 s (VMs drift on host sleep)
systemctl enable --now chronyd
chronyc makestep
hwclock --systohc
```

Verified: `System clock synchronized: yes`, `NTP service: active`.

## 8. Accounts (PDB `LEDGER`)

Privileges are granted through roles, never directly. Object grants are added in phase 2
when the `LEDGER` schema exists.

```sql
ALTER SESSION SET CONTAINER = LEDGER;
CREATE ROLE ledger_rw;
CREATE ROLE ledger_ro;
GRANT CREATE SESSION TO ledger_rw;
GRANT CREATE SESSION TO ledger_ro;
CREATE USER app_rw    IDENTIFIED BY <PW>; GRANT ledger_rw TO app_rw;
CREATE USER report_ro IDENTIFIED BY <PW>; GRANT ledger_ro TO report_ro;
CREATE USER dba_admin IDENTIFIED BY <PW>; GRANT DBA TO dba_admin;
```

| User | Role | Purpose |
|------|------|---------|
| `APP_RW` | `LEDGER_RW` | Simulator / application |
| `REPORT_RO` | `LEDGER_RO` | Read-only reporting |
| `DBA_ADMIN` | `DBA` | Administration (local to the PDB) |

Unquoted Oracle passwords allow only letters, digits, `_`, `$`, `#`. A password containing `@`
fails with `ORA-00922`; `@` also breaks `user/password@host` connect strings, so it is avoided.

Verified:
- `sqlplus app_rw@//vm-oracle.lab:1521/ledger` → `CON_NAME = LEDGER`, `USER = APP_RW`.
- DBeaver from Windows (`192.168.56.10:1521`, Service Name `LEDGER`): `dba_admin` connects.
- `report_ro`: `CREATE TABLE t(x int)` → `ORA-01031: insufficient privileges` (expected).

## Troubleshooting log

Problems hit during this install, in order. Kept because each one is a real diagnosis.

### 1. vCPU starvation (`rcu_sched detected stalls`)

**Symptom:** console flooded with `rcu: rcu_sched kthread starved for 60017 jiffies ... cpu=2`;
installer and first boot extremely slow.

**Checked:** `VBox.log` showed `HM: HMR3Init: AMD-V w/ nested paging` (no `NEM:` line), and
`VirtualMachinePlatform` / `HypervisorPlatform` were Disabled, so Hyper-V was *not* the cause.
Windows showed "Energy saver is on".

**Cause:** Windows 11 power throttling moves background processes (a headless VM) onto
efficiency scheduling; one vCPU went without CPU time for 60 s at a time.

**Fix:**
```powershell
powercfg /powerthrottling disable /path "C:\Program Files\Oracle\VirtualBox\VirtualBoxVM.exe"
powercfg /powerthrottling disable /path "C:\Program Files\Oracle\VirtualBox\VBoxHeadless.exe"
```
plus Power mode *Best performance* on AC, and the VM reduced to 2 vCPU.
After the change `dmesg | grep -c "rcu_sched detected stalls"` = 0.

### 2. Root filesystem read-only, `sshd` down after first boot

**Symptom:** `ssh` → `Connection refused`; on console `-bash: cannot create temp file ... Read-only file system`;
`mount` showed `/` as `ro`.

**Diagnosis:**
```
systemctl --failed           → systemd-remount-fs, sshd-keygen@*, auditd, tuned, systemd-hostnamed ...
journalctl -u systemd-remount-fs
    systemd-remount-fs[596]: Failed to open /etc/fstab: Permission denied
getenforce                   → Enforcing
ls -Z /etc/fstab             → system_u:object_r:root_t:s0      (should be etc_t)
```
Root could read `/etc/fstab` but the system service could not: wrong SELinux labels,
left by an installer whose final relabel did not complete under the CPU starvation above.
`systemd-remount-fs` failed, `/` stayed read-only, so `sshd-keygen` could not write host keys.

**Fix:**
```bash
mount -o remount,rw /
touch /.autorelabel
reboot
```
That alone looped (each boot was again read-only, so the relabel could not finish or remove
`/.autorelabel`). Breaking the loop: one boot with `enforcing=0` appended to the kernel line
in GRUB (`e`, End, `Ctrl+X`). The relabel completed, the VM rebooted once on its own, and came
back `Enforcing`, `/etc/fstab` = `etc_t`, `/` = `rw`, 0 failed units, `sshd` running.

### 3. NAT interface without an address

`enp0s3` was UP with no IPv4 after the above. Fixed with
`nmcli con mod enp0s3 connection.autoconnect yes && nmcli con up enp0s3`; verified with
`curl -sI https://yum.oracle.com` → `HTTP/1.1 200 OK`.

### 4. systemd unit fails with `status=203/EXEC`

**Symptom:** after reboot the DB was down; `oracle-opscdb.service` failed, `203/EXEC`.

**Cause:** `ls -Z $ORACLE_HOME/bin/dbstart` → `default_t`. SELinux does not let systemd
(`init_t`) execute a `default_t` file directly. This is SELinux working as intended, not a bad label.

**Fix:** small wrapper scripts in `/usr/local/bin` (label `bin_t`, executable by systemd) that
`exec` `dbstart`/`dbshut` (section 6). SELinux stays enforcing with no custom policy.

### 5. Clock 40 minutes behind

Minimal Install ships without chrony; combined with the stalls the clock drifted.
Fixed in section 7. Matters for archivelog timestamps, PITR and backup schedules.

### Other notes

- VirtualBox reported `Interface "VirtualBox Host-Only Ethernet Adapter" is of type bridged`
  on `modifyvm`; harmless, `nic2="hostonly"` was applied.
- `modifyvm` fails with `already locked for a session` while a hung `VirtualBoxVM.exe` holds
  the VM; ending that process releases the lock.
- In SQL*Plus, shell commands pasted at the `SQL>` prompt give `SP2-0734`; an `EXIT` typed with
  the Vietnamese IME active arrives as `SP2-0042: unknown command "�exit"`. Switch the IME to English.

## Known lab limitations

- Single instance, no Data Guard (needs a second host); covered by RMAN backups and restore drills in phase 3.
- Swap 3 GB < recommended 4 GB.
- 2 vCPU instead of the planned 3.
