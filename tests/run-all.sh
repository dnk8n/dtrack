#!/usr/bin/env bash
# Run all three test suites in parallel, each in its own isolated compose
# project (see tests/lib.sh). Per-suite output is captured to tests/logs/
# and printed grouped when everything has finished.
set -euo pipefail
cd "$(dirname "$0")"

# Serialize the pieces parallel runs would race on: the shared node_modules,
# and the postgres image layer cache (three cold concurrent builds would
# each compile cyanaudit from scratch — warmed once, the parallel builds of
# the per-project tags are pure cache hits).
[ -d node_modules ] || npm ci
echo "--> Warming the postgres image build cache"
(
    export TEST_SUITE=db
    # shellcheck source=lib.sh
    source ./lib.sh
    cd "${REPO_ROOT}"
    docker compose build postgres
)

mkdir -p logs
suites=(db api e2e)
pids=()
for suite in "${suites[@]}"; do
    echo "--> Launching ${suite} suite (log: tests/logs/${suite}.log)"
    "./run-${suite}-tests.sh" >"logs/${suite}.log" 2>&1 &
    pids+=("$!")
done

overall=0
results=()
for i in "${!suites[@]}"; do
    if wait "${pids[$i]}"; then
        results[i]="PASS"
    else
        results[i]="FAIL"
        overall=1
    fi
done

for i in "${!suites[@]}"; do
    echo
    echo "===================== ${suites[$i]} — ${results[$i]} ====================="
    cat "logs/${suites[$i]}.log"
done

echo
for i in "${!suites[@]}"; do
    echo "${suites[$i]}: ${results[$i]}"
done
exit "${overall}"
