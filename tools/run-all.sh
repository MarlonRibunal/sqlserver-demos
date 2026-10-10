#!/usr/bin/env bash
#
# run-all.sh -- run every topic against one container and summarise.
#
#   tools/run-all.sh [container]
#
# Runs tools/run-topic.sh for each folder that has a 01-setup.sql, in
# alphabetical order. Exit status is 1 if any topic FAILED, 0 otherwise
# (warnings and skips do not fail the run).

set -uo pipefail
container="${1:-${SQL_CONTAINER:-sqldemo-2022}}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

pass=0; warn=0; fail=0; skip=0
for dir in "$repo_root"/*/; do
    [[ -f "$dir/01-setup.sql" ]] || continue
    out="$("$repo_root/tools/run-topic.sh" "$(basename "$dir")" "$container")"
    status=$?
    echo "$out"
    case $status in
        0) if [[ "$out" == WARN* ]]; then warn=$((warn + 1)); else pass=$((pass + 1)); fi ;;
        2) skip=$((skip + 1)) ;;
        *) fail=$((fail + 1)) ;;
    esac
done

echo
echo "$container: $pass passed, $warn passed with warnings, $skip skipped, $fail failed"
[[ $fail -eq 0 ]]
