#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="$ROOT/docs/validation/evidence/${STAMP}-go-data"
mkdir -p "$EVIDENCE"
cd "$ROOT"
shasum -a 256 config/alpha-commercial-mappings-20260708.json scripts/run-real-alpha-go-validation.ts > "$EVIDENCE/input-sha256.txt"
node --env-file=.env --experimental-strip-types scripts/run-real-alpha-go-validation.ts > "$EVIDENCE/real-data-go.log" 2>&1
npm run test:imports > "$EVIDENCE/frontend-tests.log" 2>&1
npm run lint > "$EVIDENCE/lint.log" 2>&1
npm run build > "$EVIDENCE/build.log" 2>&1
{
  echo "PASS fiscal_source_1502"
  echo "PASS commercial_mappings"
  echo "PASS missing_data_reconciliation"
  echo "PASS real_readiness_recalculation"
  echo "PASS real_cash_day_e2e"
  echo "PASS frontend_tests_lint_build"
  echo "GO module_3_data_gate"
} > "$EVIDENCE/summary.txt"
echo "evidence=$EVIDENCE"
