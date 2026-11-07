#!/usr/bin/env bash
# Every TC-… id referenced by an automated test must be documented in
# docs/test-cases.md. (One-way check: the catalog may also contain manual and
# planned cases that have no automation yet.)
set -euo pipefail
cd "$(dirname "$0")/.."

catalog=docs/test-cases.md
missing=0

ids=$(grep -rhoE 'TC-[A-Z]+-[0-9]+' tests/db tests/api tests/e2e | sort -u)
for id in $ids; do
    if ! grep -q "$id" "$catalog"; then
        echo "MISSING from $catalog: $id"
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    exit 1
fi
echo "All referenced test case ids are documented in $catalog."
