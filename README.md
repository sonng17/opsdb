# OpsDB

Order-to-Cash system running on four databases (Oracle 19c, SQL Server 2022, MySQL 8.4, MongoDB 8.0),
migrated to AWS (RDS PostgreSQL, RDS MySQL) and loaded nightly into BigQuery.
This is a DBA portfolio project: the application is a Python simulator, the work is in the database layer.

## Architecture
_TODO: diagram_

| Module    | Engine            | Notes                                  |
|-----------|-------------------|----------------------------------------|
| Orders    | MySQL 8.4         | primary + GTID replica                 |
| Inventory | SQL Server 2022   | reservations, stock movements          |
| Ledger    | Oracle 19c        | payments, double-entry journal         |
| Audit     | MongoDB 8.0       | 3-node replica set                     |

## Lab setup
Two VirtualBox VMs on a 16 GB Windows laptop, host-only network `192.168.56.0/24`.
VMs are created by [`scripts/lab/create-vms.ps1`](scripts/lab/create-vms.ps1).

| VM | OS | RAM / vCPU | Runs |
|----|----|-----------|------|
| `vm-oracle` 192.168.56.10 | Oracle Linux 8.10 | 4 GB / 2 | Oracle 19c EE: CDB `OPSCDB`, PDB `LEDGER`, ARCHIVELOG |
| `vm-apps` 192.168.56.20 | Ubuntu 22.04.5 Server | 5 GB / 2 | SQL Server 2022 Developer, MySQL 8.4 primary, MySQL 8.4 replica (Docker) |

Install guides with every command, parameter choice and the problems hit:
[Oracle](docs/install/oracle.md) · [SQL Server](docs/install/mssql.md) · [MySQL](docs/install/mysql.md).

## Measured results
_Only real numbers measured in this lab._

| Metric | Value |
|--------|-------|
| Rows seeded | _TODO_ |
| RPO / RTO (restore drills) | _TODO_ |
| Migration downtime (Oracle -> RDS PostgreSQL) | _TODO_ |
| Tuning (before -> after) | _TODO_ |

## Repository layout
- `db/` schema migrations (Flyway) and hand-written rollback scripts per engine
- `backup/` RMAN, SQL Server, XtraBackup scripts, S3 sync
- `monitoring/` Prometheus, Grafana, alert rules
- `infra/aws/` Terraform
- `simulator/` data seeding and Order-to-Cash load generator
- `etl/` nightly pipeline to BigQuery
- `docs/` install guides, runbooks, postmortems, tuning log, migration docs, ADRs
