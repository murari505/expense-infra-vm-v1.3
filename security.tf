# Chained, least-privilege security groups:
#   internet -> alb (80, 443) -> frontend (80) -> backend (8080) -> mysql (3306)
# plus SSH from admin_cidr to every VM,
# plus monitoring ports (see "monitoring" below): the exporters (installed by
# userdata) and the Prometheus UI on the monitoring VM,
# plus Grafana (3000) and blackbox_exporter (9115) from admin_cidr only.

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public HTTP/HTTPS to the ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-alb-sg", Tier = "edge" }
}

resource "aws_security_group" "frontend" {
  name        = "${var.project}-frontend-sg"
  description = "nginx from the ALB, SSH from admin"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-frontend-sg", Tier = "frontend" }
}

resource "aws_security_group" "backend" {
  name        = "${var.project}-backend-sg"
  description = "API from the frontend, SSH from admin"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-backend-sg", Tier = "backend" }
}

resource "aws_security_group" "mysql" {
  name        = "${var.project}-mysql-sg"
  description = "MySQL from the backend, SSH from admin"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-mysql-sg", Tier = "db" }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.project}-monitoring-sg"
  description = "Prometheus, Grafana, blackbox and node_exporter, SSH from admin"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-monitoring-sg", Tier = "monitoring" }
}

# ---- inbound ------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirected to HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "nginx from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_frontend" {
  security_group_id            = aws_security_group.backend.id
  description                  = "API from frontend nginx"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = local.backend_port
  to_port                      = local.backend_port
}

resource "aws_vpc_security_group_ingress_rule" "mysql_from_backend" {
  security_group_id            = aws_security_group.mysql.id
  description                  = "MySQL from the backend"
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = local.mysql_port
  to_port                      = local.mysql_port
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = {
    frontend   = aws_security_group.frontend.id
    backend    = aws_security_group.backend.id
    mysql      = aws_security_group.mysql.id
    monitoring = aws_security_group.monitoring.id
  }

  security_group_id = each.value
  description       = "SSH from admin_cidr"
  cidr_ipv4         = local.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# ---- monitoring: exporter and metrics ports ------------------------------------
# Sources: admin_cidr (your machine), the VPC CIDR (the monitoring VM, which
# scrapes over private IPs) and any extra var.monitoring_cidrs (a Prometheus
# server elsewhere).
#   all VMs     9100  node_exporter
#   backend     9101  backend app /metrics (built into the app)
#   mysql       9104  mysqld_exporter
#   frontend    9113  nginx exporter
#   monitoring  9090  Prometheus UI / API
# Grafana (3000) and blackbox_exporter (9115) are in admin_ports instead: a UI
# and a probe proxy, opened to your machine only, never to the VPC or
# monitoring_cidrs. Prometheus reaches both over localhost.

locals {
  monitoring_ports = {
    frontend   = { sg = aws_security_group.frontend.id, ports = { node_exporter = 9100, nginx_exporter = 9113 } }
    backend    = { sg = aws_security_group.backend.id, ports = { node_exporter = 9100, backend_metrics = local.backend_metrics_port } }
    mysql      = { sg = aws_security_group.mysql.id, ports = { node_exporter = 9100, mysqld_exporter = 9104 } }
    monitoring = { sg = aws_security_group.monitoring.id, ports = { node_exporter = 9100, prometheus = 9090 } }
  }

  # Monitoring VM ports open to admin_cidr ONLY.
  admin_ports = {
    grafana  = 3000
    blackbox = 9115
  }

  monitoring_sources = distinct(concat([local.admin_cidr, aws_vpc.main.cidr_block], var.monitoring_cidrs))

  # One rule per (tier, port, source CIDR), keyed e.g. "backend-backend_metrics-10.0.0.0/16".
  monitoring_rules = merge([
    for tier, cfg in local.monitoring_ports : merge([
      for name, port in cfg.ports : {
        for cidr in local.monitoring_sources :
        "${tier}-${name}-${cidr}" => { sg = cfg.sg, name = name, port = port, cidr = cidr }
      }
    ]...)
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "monitoring" {
  for_each = local.monitoring_rules

  security_group_id = each.value.sg
  description       = "${each.value.name} from ${each.value.cidr}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_admin" {
  for_each = local.admin_ports

  security_group_id = aws_security_group.monitoring.id
  description       = "${each.key} from admin_cidr"
  cidr_ipv4         = local.admin_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
}

# ---- outbound: everything (package installs, git clone, DNS) -----------------

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    alb        = aws_security_group.alb.id
    frontend   = aws_security_group.frontend.id
    backend    = aws_security_group.backend.id
    mysql      = aws_security_group.mysql.id
    monitoring = aws_security_group.monitoring.id
  }

  security_group_id = each.value
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
