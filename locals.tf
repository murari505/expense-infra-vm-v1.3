# ---- admin_cidr: your public IP, looked up on every plan/apply ----------------
# Only when var.admin_cidr is unset. If your IP changed since the last apply,
# the plan shows the admin security group rules being replaced: that IS the fix.
data "http" "my_ip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", chomp(self.response_body)))
      error_message = "Could not read your public IPv4 from https://checkip.amazonaws.com. Set admin_cidr = \"<your ip>/32\" in terraform.tfvars instead."
    }
  }
}

locals {
  admin_cidr = var.admin_cidr != null ? var.admin_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"

  app_fqdn = "${var.app_hostname}.${var.domain_name}"

  # Components reach each other ONLY through these Route53 names, never through
  # IPs baked into userdata (naming-conventions §2.3: <service>.<domain_name>).
  # A replaced VM gets a new private IP; its record is updated in place and the
  # other VMs keep working without being rebuilt.
  tier_hostnames = {
    frontend = "frontend.${var.domain_name}"
    backend  = "backend.${var.domain_name}"
    mysql    = "mysql.${var.domain_name}"
  }

  # Short TTL so a replaced VM is reachable again within about a minute.
  internal_record_ttl = 60

  backend_port = 8080
  mysql_port   = 3306

  # The backend's own metrics port (the app's default, unless overridden via
  # backend_extra_env). Used by the security group and the setup check.
  backend_metrics_port = tonumber(lookup(var.backend_extra_env, "METRICS_PORT", "9101"))

  # ---- instance tags: what EC2 service discovery filters and relabels on --------
  # Prometheus sees each one as __meta_ec2_tag_<Key>, e.g. __meta_ec2_tag_Tier.
  # Project (= var.project) comes from the provider's default_tags.
  # Monitoring = "true" marks an instance as a scrape target.
  instance_tags = {
    mysql      = { Tier = "db", Component = "mysql" }
    backend    = { Tier = "backend", Component = "expense-service" }
    frontend   = { Tier = "frontend", Component = "nginx" }
    monitoring = { Tier = "monitoring", Component = "prometheus" }
  }

  # Shared bash helpers (download + checksum, node_exporter, service start),
  # inserted into every userdata script.
  monitoring_lib = file("${path.module}/templates/monitoring-lib.sh")

  # Monitoring-VM-only helpers (GROW_DISK, INSTALL_TARBALL, INSTALL_BLACKBOX,
  # INSTALL_GRAFANA). Separate so the app VMs' userdata stays under 16 KB.
  monitoring_server_lib = file("${path.module}/templates/monitoring-server-lib.sh")
}
