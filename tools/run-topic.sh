#!/usr/bin/env bash
#
# run-topic.sh -- run one topic end to end against a SQL Server container,
# and check that it behaved as its README says.
#
#   tools/run-topic.sh <topic-folder> [container]
#
#   container  defaults to $SQL_CONTAINER, then sqldemo-2022 (docker-compose.yml)
#   password   $MSSQL_SA_PASSWORD, or read from the container's own environment
#
# What it does, in order:
#   1. waits for SQL Server in the container to accept connections
#   2. runs 01-setup.sql, 02-demo.sql, 02-demo.sql AGAIN (every demo must be
#      re-runnable without re-running setup), then 03-cleanup.sql
#   3. fails if any script printed an error of severity 11 or higher
#   4. reads each demo run's "ANYTHING THAT DID NOT BEHAVE AS PREDICTED"
#      result set: rows there whose verdict is INCONCLUSIVE, INTERMITTENT or
#      SKIPPED are warnings (an environment the demo could not control);
#      any other row is a failure
#   5. fails if cleanup reports the database still present
#
# A topic folder containing a file named .ci-skip is skipped; the file says
# why (for example, it needs a sample database the container does not have).
#
# Exit status: 0 = passed (possibly with warnings), 1 = failed, 2 = skipped,
# 3 = could not run.

set -uo pipefail

topic="${1:-}"
container="${2:-${SQL_CONTAINER:-sqldemo-2022}}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
topic_dir="$repo_root/${topic%/}"

if [[ -z "$topic" || ! -f "$topic_dir/01-setup.sql" ]]; then
    echo "usage: tools/run-topic.sh <topic-folder> [container]" >&2
    exit 3
fi
topic="$(basename "$topic_dir")"

if [[ -f "$topic_dir/.ci-skip" ]]; then
    echo "SKIP  $topic ($container): $(head -1 "$topic_dir/.ci-skip")"
    exit 2
fi

password="${MSSQL_SA_PASSWORD:-}"
if [[ -z "$password" ]]; then
    password="$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                | sed -n -E 's/^(MSSQL_SA_PASSWORD|SA_PASSWORD)=//p' | head -1)"
fi
if [[ -z "$password" ]]; then
    echo "ERROR $topic: no password. Set MSSQL_SA_PASSWORD, or start the container with it." >&2
    exit 3
fi

# The tools path differs between image versions; -C (trust the server
# certificate) exists only in mssql-tools18.
if docker exec "$container" test -x /opt/mssql-tools18/bin/sqlcmd 2>/dev/null; then
    sqlcmd=(/opt/mssql-tools18/bin/sqlcmd -C)
elif docker exec "$container" test -x /opt/mssql-tools/bin/sqlcmd 2>/dev/null; then
    sqlcmd=(/opt/mssql-tools/bin/sqlcmd)
else
    echo "ERROR $topic: no sqlcmd found in container $container" >&2
    exit 3
fi
# -I: QUOTED_IDENTIFIER ON, as SSMS does; several demos need it.
# -W -s'|': trimmed, pipe-separated output, which the checks below parse.
sqlcmd+=(-S localhost -U sa -P "$password" -I -W -s '|')

# Accepting a login is not enough: a freshly started instance answers before
# tempdb and the system databases are online, and the first script then
# fails with Msg 615. Wait for every database to be ONLINE and for tempdb to
# take a #table.
ready_check="SET NOCOUNT ON; CREATE TABLE #ready (i int);
IF EXISTS (SELECT 1 FROM sys.databases WHERE state_desc <> 'ONLINE') RAISERROR('not ready', 16, 1);"
ready=0
for _ in $(seq 1 90); do
    if docker exec "$container" "${sqlcmd[@]}" -b -Q "$ready_check" >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
if [[ $ready -ne 1 ]]; then
    echo "ERROR $topic: SQL Server in $container was not ready (all databases online) within 90 s" >&2
    exit 3
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/run-topic.$topic.XXXXXX")"
# As root: docker cp creates the copy owned by root, and the container's own
# user cannot remove it. A copy left behind would make the next docker cp
# nest the new scripts INSIDE the old folder -- and sqlcmd would silently run
# the old ones.
docker exec -u 0 "$container" rm -rf "/tmp/topic-$topic" >/dev/null 2>&1
docker cp "$topic_dir" "$container:/tmp/topic-$topic" >/dev/null

run() {   # run <script> <output name>
    docker exec "$container" "${sqlcmd[@]}" -i "/tmp/topic-$topic/$1" > "$out_dir/$2.txt" 2>&1
}

start=$(date +%s)
run 01-setup.sql   setup
run 02-demo.sql    demo-1
run 02-demo.sql    demo-2
run 03-cleanup.sql cleanup
elapsed=$(( $(date +%s) - start ))
docker exec -u 0 "$container" rm -rf "/tmp/topic-$topic" >/dev/null 2>&1

failures=()
warnings=()

for f in setup demo-1 demo-2 cleanup; do
    errs=$(grep -cE '^Msg [0-9]+, Level (1[1-9]|2[0-9])' "$out_dir/$f.txt")
    if [[ $errs -gt 0 ]]; then
        failures+=("$f: $errs error(s), first: $(grep -m1 -A1 -E '^Msg [0-9]+, Level (1[1-9]|2[0-9])' "$out_dir/$f.txt" | tr '\n' ' ')")
    fi
done

# Rows of the "anything that did not behave as predicted" result set: every
# line containing '|' between that heading and the end of the demo, minus the
# column header and its dashed underline.
anomalies() {
    awk '
        /=== [0-9]+\. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===/ { inside = 1; header = 1; next }
        inside && (/DEMO COMPLETE/ || /^=== /)                       { inside = 0 }
        inside && /\|/ {
            if (header)               { header = 0; next }
            if ($0 ~ /^[-|]+$/)       { next }
            print
        }' "$1"
}

for f in demo-1 demo-2; do
    if ! grep -q 'ANYTHING THAT DID NOT BEHAVE AS PREDICTED' "$out_dir/$f.txt"; then
        failures+=("$f: never reached its final result set")
        continue
    fi
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        if [[ "$row" =~ INCONCLUSIVE|INTERMITTENT|SKIPPED ]]; then
            warnings+=("$f: $row")
        else
            failures+=("$f: $row")
        fi
    done < <(anomalies "$out_dir/$f.txt")
done

if grep -q 'STILL PRESENT' "$out_dir/cleanup.txt"; then
    failures+=("cleanup: the demo database is still present")
fi

if [[ ${#failures[@]} -gt 0 ]]; then
    echo "FAIL  $topic ($container, ${elapsed}s)  output: $out_dir"
    printf '      %s\n' "${failures[@]}" "${warnings[@]+"${warnings[@]}"}"
    exit 1
elif [[ ${#warnings[@]} -gt 0 ]]; then
    echo "WARN  $topic ($container, ${elapsed}s)  output: $out_dir"
    printf '      %s\n' "${warnings[@]}"
    exit 0
else
    echo "PASS  $topic ($container, ${elapsed}s)"
    [[ -n "${KEEP_OUTPUT:-}" ]] && echo "      output: $out_dir" || rm -rf "$out_dir"
    exit 0
fi
