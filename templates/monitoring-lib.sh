# ---- monitoring helpers (shared by every VM; included by Terraform) ------------
# Plain bash, inserted into each userdata script with file(), so nothing in here
# is a Terraform template expression. Needs VALIDATE from the including script.
#
# Layout (same as the manual install scripts in docs/):
#   /opt/<name>-<version>/   the release, owned by system user <name>
#   /opt/<name>              symlink to the current version (upgrade = new dir + relink)

ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

# INSTALL_RELEASE <name> <version> <tarball-url> <checksums-url> <strip-components>
# Downloads a GitHub release tarball, checks its SHA-256 against the release's
# checksums file and unpacks it. Skips the download if that version is already
# installed, so re-running the script is cheap.
INSTALL_RELEASE() {
  local name="$1" ver="$2" url="$3" sums_url="$4" strip="$5"
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
    tmp="$(mktemp -d)"
    curl -fsSL --retry 5 --retry-delay 3 -o "$tmp/$file" "$url" &&
      curl -fsSL --retry 5 --retry-delay 3 -o "$tmp/checksums.txt" "$sums_url"
    VALIDATE $? "download $file"
    (cd "$tmp" && grep "  $file\$" checksums.txt | sha256sum -c -)
    VALIDATE $? "verify SHA-256 of $file"
    rm -rf "$dir" && mkdir -p "$dir" && tar -xzf "$tmp/$file" -C "$dir" --strip-components="$strip"
    VALIDATE $? "unpack $file into $dir"
    touch "$dir/.installed"
    rm -rf "$tmp"
  fi

  ln -sfn "$dir" "/opt/$name" && chown -R "$name:$name" "$dir"
  VALIDATE $? "link /opt/$name -> $dir"
}

# OPEN_PORT <port>: only matters if firewalld is running (it is off on the
# course AMI; the security groups do the filtering).
OPEN_PORT() {
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="$1/tcp" && firewall-cmd --reload
    VALIDATE $? "open $1 in firewalld"
  fi
}

# START_SERVICE <unit>: the unit file is already written.
START_SERVICE() {
  systemctl daemon-reload && systemctl enable "$1" && systemctl restart "$1"
  VALIDATE $? "start $1"
}

# WAIT_METRIC <url> <regex> <description>: up to 60 s for the endpoint to
# answer with a line matching <regex>.
WAIT_METRIC() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 3 "$1" 2> /dev/null | grep -Eq "$2"; then
      VALIDATE 0 "$3"
      return 0
    fi
    sleep 2
  done
  echo "last response from $1:"
  curl -sS --max-time 3 "$1" | grep -E "$2|^# HELP" | head -5
  VALIDATE 1 "$3"
}

# INSTALL_NODE_EXPORTER <version>: host metrics on :9100, every VM.
INSTALL_NODE_EXPORTER() {
  local ver="$1"
  local base="https://github.com/prometheus/node_exporter/releases/download/v$ver"
  INSTALL_RELEASE node_exporter "$ver" "$base/node_exporter-$ver.linux-$ARCH.tar.gz" "$base/sha256sums.txt" 1

  cat > /etc/systemd/system/node_exporter.service << 'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/opt/node_exporter/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  VALIDATE $? "write node_exporter.service"

  OPEN_PORT 9100
  START_SERVICE node_exporter
  WAIT_METRIC http://127.0.0.1:9100/metrics '^node_load1 ' "node_exporter answers on :9100"
}
