#!/usr/bin/env bash
# Khung repo OpsDB theo muc 5.1 cua tai lieu.
# Cach dung: clone repo opsdb (rong, chi co README tu GitHub) -> cd vao -> bash init_opsdb.sh
# Chay duoc tren Git Bash (Windows), macOS, Linux.
set -euo pipefail

dirs=(
  db/oracle/migrations db/oracle/rollback db/oracle/packages
  db/mssql/migrations  db/mssql/rollback  db/mssql/procedures
  db/mysql/migrations  db/mysql/rollback  db/mysql/procedures
  db/postgres/migrations
  db/mongodb/validators
  backup/rman backup/mssql backup/mysql
  monitoring/dashboards
  infra/aws
  simulator
  etl
  scripts
  .github/workflows
  docs/install docs/runbooks docs/postmortems docs/migration docs/adr
)

for d in "${dirs[@]}"; do
  mkdir -p "$d"
  touch "$d/.gitkeep"
done

touch docs/backup-strategy.md docs/tuning-log.md docs/release-notes.md

cat > README.md <<'EOF'
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
_TODO: VM layout, how to rebuild the lab (see docs/install/)_

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
EOF

cat > .gitignore <<'EOF'
# Bo cai, ISO, file lon - khong bao gio commit
*.iso
*.zip
*.rpm
*.ova
*.vdi

# Backup / dump
*.bak
*.bkp
*.dmp
*.trn
*.xbstream
backup_out/

# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
crash.log
.terraform.lock.hcl.bak

# Bi mat
.env
*.pem
*.key
credentials*
secrets*

# Python
__pycache__/
*.pyc
.venv/
venv/

# OS / IDE
.DS_Store
Thumbs.db
.idea/
.vscode/
EOF

echo "Xong. Tiep theo:"
echo "  git add . && git commit -m 'chore: scaffold repo structure' && git push origin main"
echo "  git checkout -b develop && git push -u origin develop"
