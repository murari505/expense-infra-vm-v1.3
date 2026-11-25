# Monitoring stack configuration as code.
#
# Userdata (templates/monitoring.sh.tftpl) only INSTALLS Prometheus,
# blackbox_exporter and Grafana. Every config file lives in config/ (one-to-one
# with /etc on the VM) and is pushed here over SSH. Editing one re-runs only
# monitoring_config (and monitoring_ready): the services reload, the VM is NOT
# replaced, and the Prometheus history survives.
#
#   config/prometheus/prometheus.yml.tftpl          -> /etc/prometheus/prometheus.yml
#   config/blackbox/blackbox.yml.tftpl              -> /etc/blackbox_exporter/blackbox.yml
#   config/grafana/grafana.ini.tftpl                -> /etc/grafana/grafana.ini
#   config/grafana/provisioning/<kind>/*.yaml       -> /etc/grafana/provisioning/<kind>/
#   config/grafana/dashboards/*.json                -> /var/lib/grafana/dashboards/

locals {
  # Values the templates need. Nothing in config/ hard-codes a domain or region.
  monitoring_template_vars = {
    project                = var.project
    aws_region             = var.aws_region
    app_fqdn               = local.app_fqdn
    frontend_fqdn          = local.tier_hostnames.frontend
    backend_fqdn           = local.tier_hostnames.backend
    mysql_fqdn             = local.tier_hostnames.mysql
    vpc_resolver           = cidrhost(aws_vpc.main.cidr_block, 2) # Amazon-provided DNS: VPC base + 2
    backend_metrics_port   = local.backend_metrics_port
    grafana_admin_password = var.grafana_admin_password
  }

  # Rendered in memory and uploaded with `content`: no rendered copies on disk.
  monitoring_rendered = {
    "prometheus/prometheus.yml" = templatefile("${path.module}/config/prometheus/prometheus.yml.tftpl", local.monitoring_template_vars)
    "blackbox/blackbox.yml"     = templatefile("${path.module}/config/blackbox/blackbox.yml.tftpl", local.monitoring_template_vars)
    "grafana/grafana.ini"       = templatefile("${path.module}/config/grafana/grafana.ini.tftpl", local.monitoring_template_vars)
  }

  # Static files, uploaded as folders (a new dashboard JSON needs no Terraform change).
  monitoring_static_files = concat(
    [for f in sort(fileset("${path.module}/config", "grafana/provisioning/**")) : "config/${f}"],
    [for f in sort(fileset("${path.module}/config", "grafana/dashboards/*.json")) : "config/${f}"],
    ["templates/apply-monitoring-config.sh", "templates/monitoring-ready.sh"],
  )

  # Changes whenever any rendered or static file changes.
  monitoring_config_hash = sha256(join("\n", concat(
    [for k in sort(keys(local.monitoring_rendered)) : "${k}=${sha256(local.monitoring_rendered[k])}"],
    [for f in local.monitoring_static_files : "${f}=${filesha256("${path.module}/${f}")}"],
  )))

  # What monitoring_ready expects to find in Prometheus: active targets per job.
  monitoring_expected_targets = {
    prometheus        = 1
    node              = length(local.instances) # every VM
    nginx             = 1
    backend           = 1
    mysql             = 1
    blackbox_exporter = 1
    grafana           = 1
    blackbox_http     = 3 # https /, https /api/health/ready, http -> https redirect
    blackbox_dns      = 5 # app via public + VPC resolver, frontend/backend/mysql via VPC
  }
}

# 4. Push config/ to the monitoring VM, check it, install it, reload.
resource "terraform_data" "monitoring_config" {
  triggers_replace = [
    aws_instance.monitoring.id,
    local.monitoring_config_hash,
  ]

  connection {
    type     = "ssh"
    host     = aws_instance.monitoring.public_ip
    user     = var.ssh_user
    password = var.ssh_password
    timeout  = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "rm -rf /tmp/expense-config && mkdir -p /tmp/expense-config/prometheus /tmp/expense-config/blackbox /tmp/expense-config/grafana/provisioning /tmp/expense-config/grafana/dashboards",
    ]
  }

  provisioner "file" {
    content     = local.monitoring_rendered["prometheus/prometheus.yml"]
    destination = "/tmp/expense-config/prometheus/prometheus.yml"
  }

  provisioner "file" {
    content     = local.monitoring_rendered["blackbox/blackbox.yml"]
    destination = "/tmp/expense-config/blackbox/blackbox.yml"
  }

  provisioner "file" {
    content     = local.monitoring_rendered["grafana/grafana.ini"]
    destination = "/tmp/expense-config/grafana/grafana.ini"
  }

  # Trailing slash: upload the folder's CONTENTS into the destination folder.
  provisioner "file" {
    source      = "${path.module}/config/grafana/provisioning/"
    destination = "/tmp/expense-config/grafana/provisioning"
  }

  provisioner "file" {
    source      = "${path.module}/config/grafana/dashboards/"
    destination = "/tmp/expense-config/grafana/dashboards"
  }

  provisioner "file" {
    source      = "${path.module}/templates/apply-monitoring-config.sh"
    destination = "/tmp/expense-config/apply-monitoring-config.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash /tmp/expense-config/apply-monitoring-config.sh",
    ]
  }

  depends_on = [terraform_data.vm_ready]
}

# 6. End to end for monitoring: every target up, every probe succeeds, Grafana
#    datasource healthy, the 3 dashboards present. The apply FAILS otherwise.
resource "terraform_data" "monitoring_ready" {
  triggers_replace = [
    terraform_data.monitoring_config.id,
    terraform_data.app_ready.id,
  ]

  connection {
    type     = "ssh"
    host     = aws_instance.monitoring.public_ip
    user     = var.ssh_user
    password = var.ssh_password
    timeout  = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/templates/monitoring-ready.sh"
    destination = "/tmp/monitoring-ready.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "GRAFANA_PASSWORD='${var.grafana_admin_password}' bash /tmp/monitoring-ready.sh '${jsonencode(local.monitoring_expected_targets)}'",
    ]
  }

  depends_on = [
    terraform_data.monitoring_config,
    terraform_data.app_ready,
  ]
}
