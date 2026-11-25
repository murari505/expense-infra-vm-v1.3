#!/bin/bash
# Run on expense-monitoring by terraform_data.monitoring_ready:
#   GRAFANA_PASSWORD=... bash /tmp/monitoring-ready.sh '<expected targets per job, JSON>'
#
# Passes when ALL of these hold; retries every 10 s for up to 5 minutes (EC2
# service discovery refreshes every 60 s), then fails with the last output.
#   1. Prometheus: every expected job has its number of active targets, all up
#   2. Prometheus: min(probe_success) == 1 (every blackbox probe succeeds)
#   3. Grafana: the provisioned Prometheus datasource is healthy
#   4. Grafana: the dashboards expense-panels, node-use, blackbox-probes exist
# Plain bash (not a Terraform template).

set -u
EXPECTED="$1"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
DASHBOARDS="expense-panels node-use blackbox-probes"

CHECK_TARGETS() {
  curl -fsS --max-time 5 'http://127.0.0.1:9090/api/v1/targets?state=active' |
    python3 -c '
import json, sys
expected = json.loads(sys.argv[1])
targets = json.load(sys.stdin)["data"]["activeTargets"]
seen, bad = {}, []
for t in targets:
    job = t["labels"].get("job", t.get("scrapePool"))
    seen[job] = seen.get(job, 0) + 1
    if t["health"] != "up":
        bad.append("  %s %s: %s %s" % (job, t["labels"].get("instance"), t["health"], t.get("lastError", "")))
ok = True
for job, n in sorted(expected.items()):
    if seen.get(job, 0) != n:
        print("  job %s: %d active targets, expected %d" % (job, seen.get(job, 0), n))
        ok = False
for job in sorted(set(seen) - set(expected)):
    print("  job %s: unexpected (%d targets)" % (job, seen[job]))
if bad:
    print("  targets not up:")
    print("\n".join(bad))
    ok = False
print("  targets: %d active, %d expected, %d not up" % (len(targets), sum(expected.values()), len(bad)))
sys.exit(0 if ok else 1)
' "$EXPECTED"
}

CHECK_PROBES() {
  curl -fsS --max-time 5 --data-urlencode 'query=min(probe_success)' http://127.0.0.1:9090/api/v1/query |
    python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
v = r[0]["value"][1] if r else "none"
print("  min(probe_success) = %s" % v)
sys.exit(0 if v == "1" else 1)
'
}

CHECK_DATASOURCE() {
  local out
  out="$(curl -sS --max-time 10 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" http://127.0.0.1:3000/api/datasources/uid/prometheus/health)"
  echo "  datasource health: $out"
  echo "$out" | grep -Eq '"status": *"OK"'
}

CHECK_DASHBOARDS() {
  curl -fsS --max-time 5 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" 'http://127.0.0.1:3000/api/search?type=dash-db' |
    python3 -c '
import json, sys
have = {d["uid"] for d in json.load(sys.stdin)}
missing = [u for u in sys.argv[1].split() if u not in have]
print("  dashboards: have %s, missing %s" % (sorted(have), missing or "none"))
sys.exit(1 if missing else 0)
' "$DASHBOARDS"
}

for i in $(seq 1 30); do
  echo "---- monitoring check $i/30 ----"
  rc=0
  CHECK_TARGETS || rc=1
  CHECK_PROBES || rc=1
  CHECK_DATASOURCE || rc=1
  CHECK_DASHBOARDS || rc=1
  if [ $rc -eq 0 ]; then
    echo "monitoring is ready: all targets up, all probes succeed, Grafana datasource OK, 3 dashboards present"
    exit 0
  fi
  sleep 10
done

echo "monitoring did not become ready within 5 minutes (see the last check above)"
exit 1
