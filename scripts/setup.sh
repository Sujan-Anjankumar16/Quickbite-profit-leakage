#!/usr/bin/env bash
# =====================================================================
#  QuickBite - build everything on a fresh clone (macOS, Docker Desktop running).
#    scripts/setup.sh
#  Steps: start the containers (MySQL runs db/mysql/01-06 and MongoDB runs
#  db/mongo/01_init.js by themselves on empty volumes) -> generate and load the
#  data -> run leak detection -> seed leak notes -> build the web app.
#  Safe to re-run: the data load replaces the generated tables, and each
#  re-run adds one more detection run (history).
#  Then:  cd web && npm start   ->  http://localhost:3000
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
step() { printf '\n==> %s\n' "$1"; }
quiet() { grep -v 'Using a password' || true; }   # hide the client's password warning

[ -f .env ] || { echo "No .env: run  cp .env.example .env  and set the passwords first."; exit 1; }
command -v docker  >/dev/null || { echo "Docker Desktop is not installed or not running."; exit 1; }
command -v python3 >/dev/null || { echo "python3 is missing."; exit 1; }
command -v npm     >/dev/null || { echo "Node.js (npm) is missing: install Node 20 or newer."; exit 1; }

step "Starting MySQL, MongoDB and Redis"
docker compose up -d
for i in $(seq 1 60); do
  unhealthy=$(docker compose ps --format '{{.Health}}' | grep -vc '^healthy$' || true)
  [ "$unhealthy" -eq 0 ] && break
  sleep 5
done
docker compose ps --format '{{.Name}}  {{.Health}}'
[ "$unhealthy" -eq 0 ] || { echo "Containers did not become healthy."; exit 1; }

step "Python virtual environment and data generator"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip3 install -q -r generator/requirements.txt
.venv/bin/python3 generator/generate_data.py

step "Loading the generated data into MySQL"
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite' \
  < data/generated/quickbite_data.sql 2>&1 | quiet

step "Leak detection and recommendations (as qb_analyst_user)"
docker compose exec -T mysql sh -c 'mysql -uqb_analyst_user -pAnalyst@Dev123 -t quickbite -e "
  CALL sp_detect_leaks(\"2025-11-01\", \"2026-11-01\", @run, @leaks);
  CALL sp_generate_recommendations(@run, @recos);
  SELECT @run AS run_id, @leaks AS leak_rows, @recos AS recommendations;"' 2>&1 | quiet
# fresh statistics for the new leak rows (see the ANALYZE note in the generated data file)
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" quickbite -e "ANALYZE TABLE leakage_record, recommendation" > /dev/null' 2>&1 | quiet

step "Web app: install, seed leak notes, build"
cd web
npm ci --no-fund --no-audit
npm run --silent seed:notes
npm run build

step "Done"
echo "Start the app:   cd web && npm start      (then open http://localhost:3000)"
echo "Run all tests:   scripts/test_all.sh      (in a second terminal, with the app running)"
