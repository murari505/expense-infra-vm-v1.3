# Course AMI: RHEL 9 DevOps practice image (SSH user ec2-user).
data "aws_ami" "joindevops" {
  most_recent = true
  owners      = ["973714476881"]

  filter {
    name   = "name"
    values = ["Redhat-9-DevOps-Practice"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# No EC2 key pair: the course AMI logs in with a username and password
# (ssh_user / ssh_password in variables.tf).

# ---- secrets (never variables with defaults) ---------------------------------
# Alphanumeric only, so they are safe in shell, SQL, systemd and env files.

resource "random_password" "mysql_root" {
  length  = 24
  special = false
}

resource "random_password" "db_app" {
  length  = 24
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

# MySQL user 'exporter'@'127.0.0.1', used only by mysqld_exporter.
resource "random_password" "mysql_exporter" {
  length  = 24
  special = false
}

# ---- instances -----------------------------------------------------------------
# Userdata never contains another VM's IP: each VM reaches its upstream through
# the upstream's Route53 record (dns.tf). Each instance waits for its upstream's
# record to EXIST before booting (depends_on), so the first lookup never hits a
# missing name: resolvers cache "no such name" for up to 15 minutes. depends_on
# only orders creation; it never forces a replacement.
#
# Every VM also runs node_exporter (:9100); mysql adds mysqld_exporter (:9104),
# frontend adds the nginx exporter (:9113). Tags (locals.tf instance_tags) are
# what Prometheus EC2 service discovery filters on.

resource "aws_instance" "mysql" {
  ami                         = data.aws_ami.joindevops.id
  instance_type               = var.mysql_instance_type
  subnet_id                   = aws_subnet.public["a"].id
  vpc_security_group_ids      = [aws_security_group.mysql.id]
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/mysql.sh.tftpl", {
    hostname                = "${var.project}-mysql"
    mysql_root_password     = random_password.mysql_root.result
    db_name                 = var.db_name
    db_user                 = var.db_user
    db_password             = random_password.db_app.result
    repo_url                = var.mysql_repo_url
    repo_ref                = var.mysql_repo_ref
    monitoring_lib          = local.monitoring_lib
    node_exporter_version   = var.node_exporter_version
    mysqld_exporter_version = var.mysqld_exporter_version
    mysql_exporter_password = random_password.mysql_exporter.result
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  tags        = merge({ Name = "${var.project}-mysql", Monitoring = "true" }, local.instance_tags.mysql)
  volume_tags = merge({ Name = "${var.project}-mysql", Project = var.project, Environment = "lab", ManagedBy = "terraform" }, local.instance_tags.mysql)
}

resource "aws_instance" "backend" {
  ami                         = data.aws_ami.joindevops.id
  instance_type               = var.backend_instance_type
  subnet_id                   = aws_subnet.public["b"].id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/backend.sh.tftpl", {
    hostname              = "${var.project}-backend"
    node_version          = var.node_version
    repo_url              = var.backend_repo_url
    repo_ref              = var.backend_repo_ref
    port                  = local.backend_port
    metrics_port          = local.backend_metrics_port
    db_host               = local.tier_hostnames.mysql
    db_port               = local.mysql_port
    db_name               = var.db_name
    db_user               = var.db_user
    db_password           = random_password.db_app.result
    jwt_secret            = random_password.jwt_secret.result
    extra_env             = var.backend_extra_env
    monitoring_lib        = local.monitoring_lib
    node_exporter_version = var.node_exporter_version
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  tags        = merge({ Name = "${var.project}-backend", Monitoring = "true" }, local.instance_tags.backend)
  volume_tags = merge({ Name = "${var.project}-backend", Project = var.project, Environment = "lab", ManagedBy = "terraform" }, local.instance_tags.backend)

  depends_on = [aws_route53_record.mysql]
}

resource "aws_instance" "frontend" {
  ami                         = data.aws_ami.joindevops.id
  instance_type               = var.frontend_instance_type
  subnet_id                   = aws_subnet.public["a"].id
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/frontend.sh.tftpl", {
    hostname               = "${var.project}-frontend"
    node_version           = var.node_version
    repo_url               = var.frontend_repo_url
    repo_ref               = var.frontend_repo_ref
    backend_host           = local.tier_hostnames.backend
    backend_port           = local.backend_port
    monitoring_lib         = local.monitoring_lib
    node_exporter_version  = var.node_exporter_version
    nginx_exporter_version = var.nginx_exporter_version
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  tags        = merge({ Name = "${var.project}-frontend", Monitoring = "true" }, local.instance_tags.frontend)
  volume_tags = merge({ Name = "${var.project}-frontend", Project = var.project, Environment = "lab", ManagedBy = "terraform" }, local.instance_tags.frontend)

  depends_on = [aws_route53_record.backend]
}

# ---- monitoring: Prometheus, blackbox_exporter, Grafana ----------------------------
# Created LAST: after the three app VMs and the ALB exist, so everything it
# will discover is already there. depends_on only orders creation; replacing
# an app VM later does NOT replace this one, so the metrics history survives.
# Its userdata contains nothing about the other VMs: EC2 service discovery
# finds them at runtime, using the instance role (iam.tf).

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ami.joindevops.id
  instance_type               = var.monitoring_instance_type
  subnet_id                   = aws_subnet.public["b"].id
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.prometheus.name
  user_data_replace_on_change = true

  # Install only: config files come from config/ via monitoring_config
  # (monitoring-config.tf), so editing them never replaces this VM.
  user_data = templatefile("${path.module}/templates/monitoring.sh.tftpl", {
    hostname                  = "${var.project}-monitoring"
    monitoring_lib            = local.monitoring_lib
    monitoring_server_lib     = local.monitoring_server_lib
    node_exporter_version     = var.node_exporter_version
    prometheus_version        = var.prometheus_version
    prometheus_retention      = var.prometheus_retention
    blackbox_exporter_version = var.blackbox_exporter_version
    grafana_version           = var.grafana_version
    grafana_build             = var.grafana_build
    grafana_sha256            = var.grafana_sha256
    root_size_gb              = 16
    var_size_gb               = 12
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = var.monitoring_volume_size
  }

  tags        = merge({ Name = "${var.project}-monitoring", Monitoring = "true" }, local.instance_tags.monitoring)
  volume_tags = merge({ Name = "${var.project}-monitoring", Project = var.project, Environment = "lab", ManagedBy = "terraform" }, local.instance_tags.monitoring)

  depends_on = [
    aws_instance.frontend,
    aws_instance.backend,
    aws_instance.mysql,
    aws_lb.main,
  ]
}
