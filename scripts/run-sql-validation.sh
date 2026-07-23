#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="$ROOT/docs/validation/evidence/$STAMP"
DB_CONTAINER="supabase_db_satrapy-validation"

mkdir -p "$EVIDENCE"
{
  echo "timestamp_utc=$STAMP"
  echo "node=$(node --version)"
  echo "supabase=$(supabase --version)"
  echo "docker=$(docker --version)"
} > "$EVIDENCE/environment.txt"

find "$ROOT/supabase/migrations" -type f -name '*.sql' -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 > "$EVIDENCE/migration-sha256.txt"
find "$ROOT/supabase/tests" "$ROOT/supabase/concurrency" -type f -name '*.sql' -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 > "$EVIDENCE/test-sha256.txt"

cd "$ROOT"
supabase start > "$EVIDENCE/supabase-start.log" 2>&1 || {
  supabase status > "$EVIDENCE/supabase-status.log" 2>&1
}
supabase db reset > "$EVIDENCE/migration-reset.log" 2>&1

passed=0
failed=0
for test_file in "$ROOT"/supabase/tests/*.sql; do
  test_name="$(basename "$test_file" .sql)"
  if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      < "$test_file" > "$EVIDENCE/$test_name.log" 2>&1; then
    echo "PASS $test_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $test_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
done

concurrency_name="concurrency_sales"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v label=last-a \
    < "$ROOT/supabase/concurrency/sell-last.sql" > "$EVIDENCE/${concurrency_name}-last-a.log" 2>&1 &
  last_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v label=last-b \
    < "$ROOT/supabase/concurrency/sell-last.sql" > "$EVIDENCE/${concurrency_name}-last-b.log" 2>&1 &
  last_b_pid=$!
  wait "$last_a_pid"; last_a_status=$?
  wait "$last_b_pid"; last_b_status=$?

  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/sell-idempotent.sql" > "$EVIDENCE/${concurrency_name}-idem-a.log" 2>&1 &
  idem_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/sell-idempotent.sql" > "$EVIDENCE/${concurrency_name}-idem-b.log" 2>&1 &
  idem_b_pid=$!
  wait "$idem_a_pid"; idem_a_status=$?
  wait "$idem_b_pid"; idem_b_status=$?
  set -e

  if { test "$last_a_status" -eq 0 && test "$last_b_status" -ne 0; } \
      || { test "$last_a_status" -ne 0 && test "$last_b_status" -eq 0; }; then
    last_stock_ok=1
  else
    last_stock_ok=0
  fi
  if test "$idem_a_status" -eq 0 && test "$idem_b_status" -eq 0; then idem_ok=1; else idem_ok=0; fi

  if test "$last_stock_ok" -eq 1 && test "$idem_ok" -eq 1 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_purchase_receipts"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/receipts-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/receipt-confirm-same.sql" > "$EVIDENCE/${concurrency_name}-same-a.log" 2>&1 &
  receipt_same_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/receipt-confirm-same.sql" > "$EVIDENCE/${concurrency_name}-same-b.log" 2>&1 &
  receipt_same_b_pid=$!
  wait "$receipt_same_a_pid"; receipt_same_a_status=$?
  wait "$receipt_same_b_pid"; receipt_same_b_status=$?
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=a \
    < "$ROOT/supabase/concurrency/receipt-confirm-overflow.sql" > "$EVIDENCE/${concurrency_name}-overflow-a.log" 2>&1 &
  receipt_overflow_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=b \
    < "$ROOT/supabase/concurrency/receipt-confirm-overflow.sql" > "$EVIDENCE/${concurrency_name}-overflow-b.log" 2>&1 &
  receipt_overflow_b_pid=$!
  wait "$receipt_overflow_a_pid"; receipt_overflow_a_status=$?
  wait "$receipt_overflow_b_pid"; receipt_overflow_b_status=$?
  set -e
  if test "$receipt_same_a_status" -eq 0 && test "$receipt_same_b_status" -eq 0; then receipt_same_ok=1; else receipt_same_ok=0; fi
  if { test "$receipt_overflow_a_status" -eq 0 && test "$receipt_overflow_b_status" -ne 0; } \
      || { test "$receipt_overflow_a_status" -ne 0 && test "$receipt_overflow_b_status" -eq 0; }; then receipt_overflow_ok=1; else receipt_overflow_ok=0; fi
  if test "$receipt_same_ok" -eq 1 && test "$receipt_overflow_ok" -eq 1 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/receipt-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_supplier_invoices"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/invoices-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/invoice-confirm-same.sql" > "$EVIDENCE/${concurrency_name}-same-a.log" 2>&1 &
  invoice_same_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/invoice-confirm-same.sql" > "$EVIDENCE/${concurrency_name}-same-b.log" 2>&1 &
  invoice_same_b_pid=$!
  wait "$invoice_same_a_pid"; invoice_same_a_status=$?
  wait "$invoice_same_b_pid"; invoice_same_b_status=$?
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=a \
    < "$ROOT/supabase/concurrency/invoice-confirm-overflow.sql" > "$EVIDENCE/${concurrency_name}-overflow-a.log" 2>&1 &
  invoice_overflow_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=b \
    < "$ROOT/supabase/concurrency/invoice-confirm-overflow.sql" > "$EVIDENCE/${concurrency_name}-overflow-b.log" 2>&1 &
  invoice_overflow_b_pid=$!
  wait "$invoice_overflow_a_pid"; invoice_overflow_a_status=$?
  wait "$invoice_overflow_b_pid"; invoice_overflow_b_status=$?
  set -e
  if test "$invoice_same_a_status" -eq 0 && test "$invoice_same_b_status" -eq 0; then invoice_same_ok=1; else invoice_same_ok=0; fi
  if { test "$invoice_overflow_a_status" -eq 0 && test "$invoice_overflow_b_status" -ne 0; } \
      || { test "$invoice_overflow_a_status" -ne 0 && test "$invoice_overflow_b_status" -eq 0; }; then invoice_overflow_ok=1; else invoice_overflow_ok=0; fi
  if test "$invoice_same_ok" -eq 1 && test "$invoice_overflow_ok" -eq 1 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/invoice-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_supplier_payments"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/supplier-payments-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=a \
    < "$ROOT/supabase/concurrency/supplier-payment-overlap.sql" > "$EVIDENCE/${concurrency_name}-overlap-a.log" 2>&1 &
  payment_overlap_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v side=b \
    < "$ROOT/supabase/concurrency/supplier-payment-overlap.sql" > "$EVIDENCE/${concurrency_name}-overlap-b.log" 2>&1 &
  payment_overlap_b_pid=$!
  wait "$payment_overlap_a_pid"; payment_overlap_a_status=$?
  wait "$payment_overlap_b_pid"; payment_overlap_b_status=$?
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/supplier-payment-idempotent.sql" > "$EVIDENCE/${concurrency_name}-idem-a.log" 2>&1 &
  payment_idem_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/supplier-payment-idempotent.sql" > "$EVIDENCE/${concurrency_name}-idem-b.log" 2>&1 &
  payment_idem_b_pid=$!
  wait "$payment_idem_a_pid"; payment_idem_a_status=$?
  wait "$payment_idem_b_pid"; payment_idem_b_status=$?
  set -e
  if { test "$payment_overlap_a_status" -eq 0 && test "$payment_overlap_b_status" -ne 0; } \
      || { test "$payment_overlap_a_status" -ne 0 && test "$payment_overlap_b_status" -eq 0; }; then payment_overlap_ok=1; else payment_overlap_ok=0; fi
  if test "$payment_idem_a_status" -eq 0 && test "$payment_idem_b_status" -eq 0; then payment_idem_ok=1; else payment_idem_ok=0; fi
  if test "$payment_overlap_ok" -eq 1 && test "$payment_idem_ok" -eq 1 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/supplier-payments-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_banking"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/banking-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/banking-promote.sql" > "$EVIDENCE/${concurrency_name}-a.log" 2>&1 &
  banking_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/banking-promote.sql" > "$EVIDENCE/${concurrency_name}-b.log" 2>&1 &
  banking_b_pid=$!
  wait "$banking_a_pid"; banking_a_status=$?
  wait "$banking_b_pid"; banking_b_status=$?
  set -e
  if test "$banking_a_status" -eq 0 && test "$banking_b_status" -eq 0 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/banking-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_accounting_reports"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/accounting-report-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/accounting-report-query.sql" > "$EVIDENCE/${concurrency_name}-a.log" 2>&1 &
  close_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/accounting-report-query.sql" > "$EVIDENCE/${concurrency_name}-b.log" 2>&1 &
  close_b_pid=$!
  wait "$close_a_pid"; close_a_status=$?
  wait "$close_b_pid"; close_b_status=$?
  set -e
  if test "$close_a_status" -eq 0 && test "$close_b_status" -eq 0 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/accounting-report-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_accounting_classification"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/accounting-classification-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/accounting-classification-a.sql" > "$EVIDENCE/${concurrency_name}-a.log" 2>&1 &
  classification_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/accounting-classification-b.sql" > "$EVIDENCE/${concurrency_name}-b.log" 2>&1 &
  classification_b_pid=$!
  wait "$classification_a_pid"; classification_a_status=$?
  wait "$classification_b_pid"; classification_b_status=$?
  set -e
  if test "$classification_a_status" -eq 0 && test "$classification_b_status" -eq 0 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/accounting-classification-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

concurrency_name="concurrency_cash_custody"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/cash-custody-setup.sql" > "$EVIDENCE/${concurrency_name}-setup.log" 2>&1; then
  set +e
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/cash-custody-a.sql" > "$EVIDENCE/${concurrency_name}-a.log" 2>&1 &
  custody_a_pid=$!
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$ROOT/supabase/concurrency/cash-custody-b.sql" > "$EVIDENCE/${concurrency_name}-b.log" 2>&1 &
  custody_b_pid=$!
  wait "$custody_a_pid"; custody_a_status=$?
  wait "$custody_b_pid"; custody_b_status=$?
  set -e
  if { test "$custody_a_status" -eq 0 && test "$custody_b_status" -ne 0; } \
      || { test "$custody_a_status" -ne 0 && test "$custody_b_status" -eq 0; }; then custody_winner_ok=1; else custody_winner_ok=0; fi
  if test "$custody_winner_ok" -eq 1 \
      && docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        < "$ROOT/supabase/concurrency/cash-custody-verify.sql" > "$EVIDENCE/${concurrency_name}-verify.log" 2>&1; then
    echo "PASS $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
else
  echo "FAIL $concurrency_name" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

alpha_dir=$(node --env-file=.env -e 'process.stdout.write(process.env.ALPHA_ERP_IMPORT_DIR ?? "")')
if test -n "$alpha_dir" && test -d "$alpha_dir"; then
  if node --env-file=.env --experimental-strip-types scripts/inspect-alpha-exports.ts \
      > "$EVIDENCE/real-alpha-profile.log" 2>&1 \
      && node --env-file=.env --experimental-strip-types scripts/run-real-alpha-catalog-validation.ts \
      > "$EVIDENCE/real-alpha-catalog-transaction.log" 2>&1; then
    echo "PASS real_alpha_catalog_transaction" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL real_alpha_catalog_transaction" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
  for alpha_check in inspect:alpha-purchasing validate:alpha-suppliers validate:alpha-purchase-orders; do
    log_name="real-alpha-${alpha_check/:/-}"
    if npm run "$alpha_check" > "$EVIDENCE/$log_name.log" 2>&1; then
      echo "PASS real_alpha_$alpha_check" | tee -a "$EVIDENCE/summary.txt"
      passed=$((passed + 1))
    else
      echo "FAIL real_alpha_$alpha_check" | tee -a "$EVIDENCE/summary.txt"
      failed=$((failed + 1))
    fi
  done
  if grep -q '"type":"products".*"taxConfigured":0' "$EVIDENCE/real-alpha-profile.log" \
      && ! grep -Eq '"type":"products".*"taxConfigured":[1-9]' "$EVIDENCE/real-alpha-profile.log"; then
    echo "BLOCKED real_alpha_end_to_end missing_separate_fiscal_source" | tee -a "$EVIDENCE/summary.txt"
  fi
else
  echo "BLOCKED real_alpha_regression source_directory_unavailable=$alpha_dir" | tee -a "$EVIDENCE/summary.txt"
fi

for check in test:imports lint build; do
  log_name="frontend-${check/:/-}"
  if npm run "$check" > "$EVIDENCE/$log_name.log" 2>&1; then
    echo "PASS frontend_$check" | tee -a "$EVIDENCE/summary.txt"
    passed=$((passed + 1))
  else
    echo "FAIL frontend_$check" | tee -a "$EVIDENCE/summary.txt"
    failed=$((failed + 1))
  fi
done

if supabase db reset > "$EVIDENCE/final-clean-reset.log" 2>&1; then
  echo "PASS final_clean_reset" | tee -a "$EVIDENCE/summary.txt"
  passed=$((passed + 1))
else
  echo "FAIL final_clean_reset" | tee -a "$EVIDENCE/summary.txt"
  failed=$((failed + 1))
fi

echo "passed=$passed" | tee -a "$EVIDENCE/summary.txt"
echo "failed=$failed" | tee -a "$EVIDENCE/summary.txt"
echo "evidence=$EVIDENCE"
test "$failed" -eq 0
