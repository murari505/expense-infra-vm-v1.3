output "app_url" {
  description = "The app, over HTTPS."
  value       = "https://${local.app_fqdn}"
}

output "ssh_commands" {
  description = "SSH into each VM (password: the ssh_password variable, DevOps321 by default)."
  value = {
    for tier, inst in local.instances :
    tier => "ssh ${var.ssh_user}@${inst.public_ip}"
  }
}

output "tier_hostnames" {
  description = "Route53 names the VMs use to reach each other (resolve to private IPs, inside the VPC only)."
  value       = local.tier_hostnames
}

output "private_ips" {
  description = "Private IP per VM (what EC2 service discovery returns as __meta_ec2_private_ip)."
  value       = { for tier, inst in local.instances : tier => inst.private_ip }
}

output "admin_cidr" {
  description = "The CIDR the admin security group rules allow (your looked-up public IP /32 unless admin_cidr is set)."
  value       = local.admin_cidr
}

output "prometheus_url" {
  description = "Prometheus UI (open from admin_cidr). Status > Targets lists what it scrapes."
  value       = "http://${aws_instance.monitoring.public_ip}:9090"
}

output "grafana_url" {
  description = "Grafana (open from admin_cidr). Folder Expense App holds the 3 provisioned dashboards."
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
}

output "blackbox_url" {
  description = "blackbox_exporter (open from admin_cidr). The page lists recent probes and their debug logs."
  value       = "http://${aws_instance.monitoring.public_ip}:9115"
}

output "grafana_admin_password" {
  description = "Grafana login for user admin: terraform output -raw grafana_admin_password (lab default admin)."
  value       = var.grafana_admin_password
  sensitive   = true
}

output "instance_tags" {
  description = "Tags per VM that EC2 service discovery can filter / relabel on (plus Project from default_tags)."
  value       = { for tier, inst in local.instances : tier => { for k, v in inst.tags : k => v if k != "Name" } }
}

output "mysql_exporter_password" {
  description = "MySQL password of 'exporter'@'127.0.0.1' (mysqld_exporter only)."
  value       = random_password.mysql_exporter.result
  sensitive   = true
}

output "db_password" {
  description = "MySQL application user password."
  value       = random_password.db_app.result
  sensitive   = true
}

output "mysql_root_password" {
  description = "MySQL root password (root@localhost on the mysql VM)."
  value       = random_password.mysql_root.result
  sensitive   = true
}

output "jwt_secret" {
  description = "Backend JWT signing secret."
  value       = random_password.jwt_secret.result
  sensitive   = true
}
