#!/bin/bash
# Run on expense-monitoring by terraform_data.monitoring_config, as root:
#   sudo bash /tmp/expense-config/apply-monitoring-config.sh
#
# Terraform has uploaded the rendered config/ tree to /tmp/expense-config:
#   prometheus/prometheus.yml                  -> /etc/prometheus/prometheus.yml
#   blackbox/blackbox.yml                      -> /etc/blackbox_exporter/blackbox.yml
#   grafana/grafana.ini                        -> /etc/grafana/grafana.ini
#   grafana/provisioning/<kind>/*.yaml         -> /etc/grafana/provisioning/<kind>/
#   grafana/dashboards/*.json                  -> /var/lib/grafana/dashboards/
#
# 1. CHECK every file first. The first failed check stops the script and
#    nothing is installed: the running config stays as it was.
# 2. INSTALL only files whose content changed (SHA-256), with owner and mode.
# 3. RELOAD Prometheus / blackbox_exporter if their file changed; RESTART
#    Grafana once if its ini or provisioning changed (never for dashboards
#    alone: Grafana rescans the dashboards folder every 30 s).
# Plain bash (not a Terraform template); safe to re-run.

set -u
SRC=/tmp/expense-config
LOG=/var/log/expense/monitoring-config.log
mkdir -p /var/log/expense
exec > >(tee -a "$LOG") 2>&1

VALIDATE() {
  if [ "$1" -ne 0 ]; then
    echo "$(date '+%F %T') $2 ... FAILURE"
    exit 1
  else
    echo "$(date '+%F %T') $2 ... SUCCESS"
  fi
}

echo "===== monitoring config apply started $(date) ====="

# ---- 1. check -------------------------------------------------------------------
/opt/prometheus/promtool check config "$SRC/prometheus/prometheus.yml"
VALIDATE $? "promtool check config prometheus.yml"

/opt/blackbox_exporter/blackbox_exporter --config.check --config.file="$SRC/blackbox/blackbox.yml"
VALIDATE $? "blackbox_exporter --config.check blackbox.yml"

[ -s "$SRC/grafana/grafana.ini" ]
VALIDATE $? "grafana.ini present and not empty"

for f in "$SRC"/grafana/provisioning/*/*.yaml; do
  [ -e "$f" ] || continue
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f"
  VALIDATE $? "YAML parses: ${f#"$SRC"/}"
done

for f in "$SRC"/grafana/dashboards/*.json; do
  [ -e "$f" ] || continue
  python3 -m json.tool "$f" > /dev/null
  VALIDATE $? "JSON parses: ${f#"$SRC"/}"
done

# ---- 2. install -----------------------------------------------------------------
# INSTALL_FILE <src> <dest> <owner:group> <mode>; prints "changed" if it wrote.
# Runs in $(...), so a failed VALIDATE only ends the subshell: every call is
# followed by `|| exit 1`.
INSTALL_FILE() {
  local src="$1" dest="$2" owner="$3" mode="$4"
  if [ -f "$dest" ] && [ "$(sha256sum < "$src")" = "$(sha256sum < "$dest")" ]; then
    echo "unchanged: $dest" >&2
    return 0
  fi
  mkdir -p "$(dirname "$dest")" &&
    install -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$src" "$dest"
  VALIDATE $? "install $dest" >&2
  echo changed
}

PROM_CHANGED="$(INSTALL_FILE "$SRC/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml root:prometheus 0640)" || exit 1
BLACKBOX_CHANGED="$(INSTALL_FILE "$SRC/blackbox/blackbox.yml" /etc/blackbox_exporter/blackbox.yml root:blackbox_exporter 0640)" || exit 1

GRAFANA_CHANGED="$(INSTALL_FILE "$SRC/grafana/grafana.ini" /etc/grafana/grafana.ini root:grafana 0640)" || exit 1
for f in "$SRC"/grafana/provisioning/*/*.yaml; do
  [ -e "$f" ] || continue
  rel="${f#"$SRC"/grafana/provisioning/}"
  c="$(INSTALL_FILE "$f" "/etc/grafana/provisioning/$rel" root:grafana 0640)" || exit 1
  [ -n "$c" ] && GRAFANA_CHANGED=changed
done

for f in "$SRC"/grafana/dashboards/*.json; do
  [ -e "$f" ] || continue
  INSTALL_FILE "$f" "/var/lib/grafana/dashboards/$(basename "$f")" grafana:grafana 0644 > /dev/null || exit 1
done

# ---- 3. reload / restart ---------------------------------------------------------
if [ -n "$PROM_CHANGED" ]; then
  systemctl reload prometheus
  VALIDATE $? "systemctl reload prometheus"
  sleep 2
  curl -fsS --max-time 3 http://127.0.0.1:9090/metrics | grep -q '^prometheus_config_last_reload_successful 1'
  VALIDATE $? "Prometheus loaded the new config"
fi

if [ -n "$BLACKBOX_CHANGED" ]; then
  systemctl reload blackbox_exporter
  VALIDATE $? "systemctl reload blackbox_exporter"
  sleep 2
  curl -fsS --max-time 3 http://127.0.0.1:9115/metrics | grep -q '^blackbox_exporter_config_last_reload_successful 1'
  VALIDATE $? "blackbox_exporter loaded the new config"
fi

if [ -n "$GRAFANA_CHANGED" ]; then
  systemctl restart grafana
  VALIDATE $? "systemctl restart grafana"
  ok=1
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 http://127.0.0.1:3000/api/health 2> /dev/null | grep -Eq '"database": *"ok"'; then
      ok=0
      break
    fi
    sleep 2
  done
  VALIDATE $ok "Grafana healthy after restart"
fi

rm -rf "$SRC"
echo "===== monitoring config apply complete $(date) ====="
