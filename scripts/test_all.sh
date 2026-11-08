#!/usr/bin/env bash
# =====================================================================
#  QuickBite - run every test suite and check each against its expected result.
#    scripts/test_all.sh            all suites (web tests need the app running: cd web && npm start)
#    scripts/test_all.sh --no-web   database suites only
#  Read-only, apart from rows each suite rolls back or deletes itself.
#  Exit code 0 = everything passed.
# =====================================================================
set -u
cd "$(dirname "$0")/.."

FAILS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }

# run_sql FILE [extra mysql flags] -> batch (tab-separated) output, warnings removed
run_sql() {
  docker compose exec -T mysql sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --force -B $2 quickbite" \
    < "$1" 2>&1 | grep -v 'Using a password on the command line'
}

echo "== MySQL"
out=$(run_sql db/mysql/tests/constraint_tests.sql "")
n=$(grep -c '^ERROR' <<<"$out")
[ "$n" -eq 16 ] && pass "constraint_tests.sql: 16/16 bad statements rejected" \
               || fail "constraint_tests.sql" "expected 16 errors, got $n"
grep -q 'all test data rolled back' <<<"$out" || fail "constraint_tests.sql" "did not reach the ROLLBACK"

out=$(run_sql db/mysql/tests/data_checks.sql "")
bad=$(awk -F'\t' '$1 ~ /^A[0-9]+ / && $2 != "0"' <<<"$out")
cnt=$(awk -F'\t' '$1 ~ /^A[0-9]+ /' <<<"$out" | wc -l | tr -d ' ')
[ -z "$bad" ] && [ "$cnt" -eq 11 ] && pass "data_checks.sql: 11/11 integrity rules hold" \
                                 || fail "data_checks.sql" "rules found: $cnt, breaking: $bad"

out=$(run_sql db/mysql/tests/view_checks.sql "")
bad=$(awk -F'\t' '$1 ~ /^V[0-9]/ { v = ($1 ~ /^V4/) ? $2 : $NF; if (v + 0 != 0) print $1 " = " v }' <<<"$out")
cnt=$(awk -F'\t' '$1 ~ /^V[0-9]/' <<<"$out" | wc -l | tr -d ' ')
[ -z "$bad" ] && [ "$cnt" -eq 12 ] && pass "view_checks.sql: 12/12 checks are 0 (view = function, totals reconcile, worked example 28.90)" \
                                 || fail "view_checks.sql" "checks found: $cnt, non-zero: $bad"

out=$(run_sql db/mysql/demo/dml_demo.sql "")
n=$(grep -c '^ERROR' <<<"$out")
before=$(awk 'f{print; exit} /^orders_before_demo$/{f=1}' <<<"$out")
after=$(awk 'f{print; exit} /^orders_after_demo$/{f=1}' <<<"$out")
if [ "$n" -eq 2 ] && grep -q $'\t28.90$' <<<"$out" && [ -n "$before" ] && [ "$before" = "$after" ]; then
  pass "dml_demo.sql: 2 expected errors, contribution 28.90, rolled back ($after orders before and after)"
else
  fail "dml_demo.sql" "errors=$n before=$before after=$after"
fi

out=$(docker compose exec -T mysql sh -c 'mysql -uqb_analyst_user -pAnalyst@Dev123 -B quickbite' \
      < db/mysql/queries/05_queries.sql 2>&1 | grep -v 'Using a password')
n=$(grep -c '^ERROR' <<<"$out")
[ "$n" -eq 0 ] && pass "05_queries.sql: all 20 queries run as qb_analyst_user" \
              || fail "05_queries.sql" "$(grep '^ERROR' <<<"$out" | head -3)"

out=$(run_sql db/mysql/tests/procedure_checks.sql "")
n=$(grep -c '^ERROR' <<<"$out")
a2=$(awk -F'\t' '$1 ~ /^A2 /{print $2 + $3}' <<<"$out")
a3=$(awk -F'\t' '$1 ~ /^A3 /{print $4 "/" $5}' <<<"$out")
a4=$(awk -F'\t' '$1 ~ /^A4 /{print $2 + $3}' <<<"$out")
a7=$(awk -F'\t' '$1 ~ /^A7 /{print $2}' <<<"$out")
left=$(awk 'f{print; exit} /^test_recommendations_left$/{f=1}' <<<"$out")
if [ "$n" -eq 7 ] && [ "$a2" = 0 ] && [ "$a3" = "1/0" ] && [ "$a4" = 0 ] && [ "$a7" = 0 ] && [ "$left" = 0 ]; then
  pass "procedure_checks.sql: one primary per order, reconciliation holds, 7/7 trigger tests reject, rolled back"
else
  fail "procedure_checks.sql" "errors=$n A2=$a2 A3(holds/over)=$a3 A4=$a4 A7=$a7 left=$left"
fi

echo "== MongoDB + Redis"
if (cd web && npm run --silent test:step7 > "$TMP/step7" 2>&1); then
  pass "web test:step7: $(tail -1 "$TMP/step7")"
else
  fail "web test:step7" "$(grep -A1 FAIL "$TMP/step7" | head -6)"
fi

if [ "${1:-}" != "--no-web" ]; then
  echo "== Web app (http://localhost:3000)"
  if ! curl -s -o /dev/null http://localhost:3000/login; then
    fail "web test:step8" "the app is not running (cd web && npm start)"
  elif (cd web && npm run --silent test:step8 > "$TMP/step8" 2>&1); then
    pass "web test:step8: $(tail -1 "$TMP/step8")"
  else
    fail "web test:step8" "$(grep -A1 FAIL "$TMP/step8" | head -6)"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "$FAILS SUITE(S) FAILED"; fi
exit "$FAILS"
