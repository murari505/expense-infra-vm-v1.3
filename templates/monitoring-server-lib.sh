# ---- monitoring-VM helpers (plain bash, inserted with file()) ----------------
# Needs VALIDATE and monitoring-lib.sh. Not in monitoring-lib.sh because that is
# inlined into EVERY VM, and userdata is limited to 16 KB.
# Layout: /opt/<name>-<ver> + /opt/<name> symlink, /etc/<name>, /var/lib/<name>.

# GROW_DISK <root-GiB> <var-GiB>: the AMI's / is 6 GB, too small for Grafana.
# Grow partition, PV, then / and /var (-r grows XFS). Devices found at runtime.
GROW_DISK() {
  local root_target="$1" var_target="$2"
  local root_src vg pv disk partnum out rc lv target cur

  root_src="$(findmnt -no SOURCE /)"
  vg="$(lvs --noheadings -o vg_name "$root_src" 2> /dev/null | xargs)"
  if [ -z "$vg" ]; then
    echo "/ ($root_src) is not on LVM, skipping disk growth"
    df -h / /var
    return 0
  fi
  pv="$(pvs --noheadings -o pv_name -S vg_name="$vg" | head -1 | xargs)"
  # sysfs: a partition's directory sits inside its disk's (.../nvme0n1/nvme0n1p4)
  local sys
  sys="$(readlink -f "/sys/class/block/$(basename "$(readlink -f "$pv")")")"
  partnum="$(cat "$sys/partition" 2> /dev/null)"
  disk="/dev/$(basename "$(dirname "$sys")")"
  echo "root fs $root_src, VG $vg on PV $pv = partition $partnum of $disk"
  [ -n "$partnum" ] && [ -b "$disk" ] && [ ! -e "/sys/class/block/$(basename "$disk")/partition" ]
  VALIDATE $? "find the disk and partition under $pv"

  # growpart exits 1 with NOCHANGE when the partition already fills the disk.
  out="$(growpart "$disk" "$partnum" 2>&1)"
  rc=$?
  echo "$out"
  if [ $rc -ne 0 ] && ! echo "$out" | grep -q NOCHANGE; then
    VALIDATE 1 "growpart $disk $partnum"
  fi
  VALIDATE 0 "growpart $disk $partnum"

  pvresize "$pv"
  VALIDATE $? "pvresize $pv"

  for lv in "rootVol:$root_target" "varVol:$var_target"; do
    target="${lv#*:}"
    lv="${lv%%:*}"
    cur="$(lvs --noheadings --units g --nosuffix -o lv_size "$vg/$lv" | xargs)"
    if awk -v c="$cur" -v t="$target" 'BEGIN { exit !(c < t) }'; then
      lvextend -r -L "${target}G" "$vg/$lv"
      VALIDATE $? "grow $vg/$lv from ${cur}G to ${target}G"
    else
      echo "$vg/$lv is ${cur}G (target ${target}G), skipping"
    fi
  done

  df -h / /var
}

# INSTALL_TARBALL <name> <ver> <url> <sha256> <strip>: INSTALL_RELEASE with a
# pinned SHA-256 (Grafana has no checksums file). Downloads under /opt, not /tmp.
INSTALL_TARBALL() {
  local name="$1" ver="$2" url="$3" sha="$4" strip="$5"
  local dir="/opt/$name-$ver" file tmp
  file="$(basename "$url")"

  if id "$name" > /dev/null 2>&1; then
    echo "user $name exists, skipping"
  else
    useradd --system --no-create-home --shell /sbin/nologin "$name"
    VALIDATE $? "create system user $name"
  fi

  if [ -f "$dir/.installed" ]; then
    echo "$name $ver already installed, skipping download"
  else
    tmp="$(mktemp -d /opt/.download-XXXXXX)"
    curl -fsSL --retry 5 --retry-delay 3 -o "$tmp/$file" "$url"
    VALIDATE $? "download $file"
    (cd "$tmp" && echo "$sha  $file" | sha256sum -c -)
    VALIDATE $? "verify SHA-256 of $file"
    rm -rf "$dir" && mkdir -p "$dir" && tar -xzf "$tmp/$file" -C "$dir" --strip-components="$strip"
    VALIDATE $? "unpack $file into $dir"
    touch "$dir/.installed"
    rm -rf "$tmp"
  fi

  ln -sfn "$dir" "/opt/$name" && chown -R "$name:$name" "$dir"
  VALIDATE $? "link /opt/$name -> $dir"
}

# INSTALL_BLACKBOX <ver>: :9115, with the release's example config until
# monitoring_config installs the repo's.
INSTALL_BLACKBOX() {
  local ver="$1"
  local base="https://github.com/prometheus/blackbox_exporter/releases/download/v$ver"
  INSTALL_RELEASE blackbox_exporter "$ver" "$base/blackbox_exporter-$ver.linux-$ARCH.tar.gz" "$base/sha256sums.txt" 1

  mkdir -p /etc/blackbox_exporter
  VALIDATE $? "create /etc/blackbox_exporter"
  if [ -f /etc/blackbox_exporter/blackbox.yml ]; then
    echo "/etc/blackbox_exporter/blackbox.yml exists, keeping it"
  else
    install -o root -g blackbox_exporter -m 0640 /opt/blackbox_exporter/blackbox.yml /etc/blackbox_exporter/blackbox.yml
    VALIDATE $? "install the release's example blackbox.yml"
  fi

  cat > /etc/systemd/system/blackbox_exporter.service << 'UNIT'
[Unit]
Description=Prometheus Blackbox Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
ExecStart=/opt/blackbox_exporter/blackbox_exporter \
  --config.file=/etc/blackbox_exporter/blackbox.yml \
  --web.listen-address=0.0.0.0:9115
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  VALIDATE $? "write blackbox_exporter.service"

  OPEN_PORT 9115
  START_SERVICE blackbox_exporter
  WAIT_METRIC http://127.0.0.1:9115/metrics '^blackbox_exporter_build_info' "blackbox_exporter answers on :9115"
}

# INSTALL_GRAFANA <ver> <build> <sha256>: :3000 as the manual doc (Part A), with
# a minimal grafana.ini until monitoring_config installs the repo's.
INSTALL_GRAFANA() {
  local ver="$1" build="$2" sha="$3" i ok=1
  INSTALL_TARBALL grafana "$ver" "https://dl.grafana.com/grafana/release/$ver/grafana_${ver}_${build}_linux_$ARCH.tar.gz" "$sha" 1

  /opt/grafana/bin/grafana --version
  VALIDATE $? "grafana binary runs"

  mkdir -p /etc/grafana/provisioning/{datasources,dashboards,plugins,alerting} &&
    chown -R root:grafana /etc/grafana && chmod -R g+rX /etc/grafana
  VALIDATE $? "create /etc/grafana/provisioning"
  mkdir -p /var/lib/grafana/{dashboards,plugins} /var/log/grafana &&
    chown -R grafana:grafana /var/lib/grafana /var/log/grafana
  VALIDATE $? "create /var/lib/grafana and /var/log/grafana"

  if [ -f /etc/grafana/grafana.ini ]; then
    echo "/etc/grafana/grafana.ini exists, keeping it"
  else
    cat > /etc/grafana/grafana.ini << 'INI'
[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning

[server]
http_port = 3000
INI
    VALIDATE $? "write a minimal grafana.ini"
    chown root:grafana /etc/grafana/grafana.ini && chmod 0640 /etc/grafana/grafana.ini
  fi

  cat > /etc/systemd/system/grafana.service << 'UNIT'
[Unit]
Description=Grafana
Documentation=https://grafana.com/docs/grafana/latest/
Wants=network-online.target
After=network-online.target prometheus.service

[Service]
User=grafana
Group=grafana
Type=simple
WorkingDirectory=/opt/grafana
ExecStart=/opt/grafana/bin/grafana server --homepath=/opt/grafana --config=/etc/grafana/grafana.ini
Restart=on-failure
LimitNOFILE=10000

[Install]
WantedBy=multi-user.target
UNIT
  VALIDATE $? "write grafana.service"

  OPEN_PORT 3000
  START_SERVICE grafana

  # first start runs DB migrations (30-60 s): wait up to 120 s
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 http://127.0.0.1:3000/api/health 2> /dev/null | grep -Eq '"database": *"ok"'; then
      ok=0
      break
    fi
    sleep 2
  done
  curl -sS --max-time 3 http://127.0.0.1:3000/api/health
  echo
  VALIDATE $ok "GET :3000/api/health shows database ok"
}
