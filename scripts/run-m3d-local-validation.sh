#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-m3d-local"
EVIDENCE="$ROOT/docs/validation/evidence/$STAMP"
DB_CONTAINER="supabase_db_satrapy-validation"
mkdir -p "$EVIDENCE"

cd "$ROOT"
supabase start > "$EVIDENCE/supabase-start.log" 2>&1 || supabase status > "$EVIDENCE/supabase-status.log" 2>&1
supabase db reset > "$EVIDENCE/migration-reset.log" 2>&1

passed=0
failed=0
for test_file in \
  "$ROOT/supabase/tests/202607170001_supplier_invoices_payables.sql" \
  "$ROOT/supabase/tests/202607170002_complete_supplier_invoices_payables.sql" \
  "$ROOT/supabase/tests/202607170003_supplier_expense_cfdi_concepts.sql"; do
  test_name="$(basename "$test_file" .sql)"
  if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$test_file" > "$EVIDENCE/$test_name.log" 2>&1; then
    echo "PASS $test_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed+1))
  else
    echo "FAIL $test_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed+1))
  fi
done

name="concurrency_supplier_invoices"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$ROOT/supabase/concurrency/invoices-setup.sql" > "$EVIDENCE/$name-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$ROOT/supabase/concurrency/invoice-confirm-same.sql" > "$EVIDENCE/$name-same-a.log" 2>&1 & same_a=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$ROOT/supabase/concurrency/invoice-confirm-same.sql" > "$EVIDENCE/$name-same-b.log" 2>&1 & same_b=$!
  wait "$same_a"; same_a_status=$?
  wait "$same_b"; same_b_status=$?
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=a < "$ROOT/supabase/concurrency/invoice-confirm-overflow.sql" > "$EVIDENCE/$name-overflow-a.log" 2>&1 & overflow_a=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=b < "$ROOT/supabase/concurrency/invoice-confirm-overflow.sql" > "$EVIDENCE/$name-overflow-b.log" 2>&1 & overflow_b=$!
  wait "$overflow_a"; overflow_a_status=$?
  wait "$overflow_b"; overflow_b_status=$?
  set -e
  if test "$same_a_status" -eq 0 && test "$same_b_status" -eq 0 \
    && { { test "$overflow_a_status" -eq 0 && test "$overflow_b_status" -ne 0; } || { test "$overflow_a_status" -ne 0 && test "$overflow_b_status" -eq 0; }; } \
    && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$ROOT/supabase/concurrency/invoice-verify.sql" > "$EVIDENCE/$name-verify.log" 2>&1; then
    echo "PASS $name" | tee -a "$EVIDENCE/summary.txt"; passed=$((passed+1))
  else
    echo "FAIL $name" | tee -a "$EVIDENCE/summary.txt"; failed=$((failed+1))
  fi
else
  echo "FAIL $name" | tee -a "$EVIDENCE/summary.txt"; failed=$((failed+1))
fi

for check in test:imports lint build; do
  log="frontend-${check/:/-}.log"
  if npm run "$check" > "$EVIDENCE/$log" 2>&1; then
    echo "PASS frontend_$check" | tee -a "$EVIDENCE/summary.txt"; passed=$((passed+1))
  else
    echo "FAIL frontend_$check" | tee -a "$EVIDENCE/summary.txt"; failed=$((failed+1))
  fi
done

if supabase db reset > "$EVIDENCE/final-clean-reset.log" 2>&1; then
  echo "PASS final_clean_reset" | tee -a "$EVIDENCE/summary.txt"; passed=$((passed+1))
else
  echo "FAIL final_clean_reset" | tee -a "$EVIDENCE/summary.txt"; failed=$((failed+1))
fi
echo "passed=$passed" | tee -a "$EVIDENCE/summary.txt"
echo "failed=$failed" | tee -a "$EVIDENCE/summary.txt"
echo "evidence=$EVIDENCE"
test "$failed" -eq 0
