variable "aws_region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefix for names and the Project tag. Keep the default."
  type        = string
  default     = "expense"
}

variable "domain_name" {
  description = "Existing Route53 PUBLIC hosted zone, e.g. joindevops.online. Holds the app record and the per-tier records the VMs use to reach each other."
  type        = string
}

variable "app_hostname" {
  description = "App FQDN = <app_hostname>.<domain_name>."
  type        = string
  default     = "expense"
}

# Leave unset: Terraform looks up the public IP of the machine running it
# (https://checkip.amazonaws.com) on every plan/apply and uses <ip>/32
# (local.admin_cidr in locals.tf). Set it only to pin a fixed CIDR, e.g. an
# office range, or when that lookup can't work (proxy, no outbound HTTPS).
variable "admin_cidr" {
  description = "CIDR allowed to SSH and to open Prometheus/Grafana/exporters. null (default) = this machine's public IP /32, looked up at plan time."
  type        = string
  default     = null

  validation {
    condition     = var.admin_cidr == null || (can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0")
    error_message = "admin_cidr must be a valid CIDR such as 203.0.113.10/32, and must not be 0.0.0.0/0."
  }
}

variable "monitoring_cidrs" {
  description = "Extra CIDRs allowed to scrape the exporter / metrics ports (e.g. a Prometheus server outside this VPC, as its public IP /32). admin_cidr (or your looked-up IP) and the VPC CIDR are always allowed."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.monitoring_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Each monitoring_cidrs entry must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

# The course AMI (Redhat-9-DevOps-Practice) uses password SSH, no key pair.
# These are the AMI's practice credentials, not secrets. Used by the readiness
# checks and shown in the ssh_commands output.
variable "ssh_user" {
  description = "SSH user of the course AMI."
  type        = string
  default     = "ec2-user"
}

variable "ssh_password" {
  description = "SSH password of the course AMI (practice only)."
  type        = string
  default     = "DevOps321"
}

variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "backend_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "mysql_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "monitoring_instance_type" {
  description = "Monitoring VM: Prometheus, blackbox_exporter, Grafana and node_exporter. t3.small (2 GB RAM): Grafana 13 alone uses 200-300 MB."
  type        = string
  default     = "t3.small"
}

variable "monitoring_volume_size" {
  description = "Monitoring VM root EBS volume, GiB. Userdata grows / to 16 GiB and /var to 12 GiB, which needs about 20 GiB on top of the AMI's 20 GiB layout."
  type        = number
  default     = 50

  validation {
    condition     = var.monitoring_volume_size >= 40
    error_message = "monitoring_volume_size must be at least 40 (GiB): / grows by 10 GiB and /var by 10 GiB."
  }
}

# ---- monitoring versions (GitHub releases, SHA-256 checked at install) -------
# Changing one re-renders that VM's userdata, which replaces the VM.

variable "node_exporter_version" {
  description = "prometheus/node_exporter release, every VM (:9100)."
  type        = string
  default     = "1.12.1"
}

variable "mysqld_exporter_version" {
  description = "prometheus/mysqld_exporter release, mysql VM (:9104)."
  type        = string
  default     = "0.21.0"
}

variable "nginx_exporter_version" {
  description = "nginx/nginx-prometheus-exporter release, frontend VM (:9113)."
  type        = string
  default     = "1.5.3"
}

variable "prometheus_version" {
  description = "prometheus/prometheus release, monitoring VM (:9090)."
  type        = string
  default     = "3.16.0"
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps samples (--storage.tsdb.retention.time)."
  type        = string
  default     = "15d"
}

variable "blackbox_exporter_version" {
  description = "prometheus/blackbox_exporter release, monitoring VM (:9115)."
  type        = string
  default     = "0.29.1"
}

# ---- Grafana (not a GitHub release: no checksums file, so the SHA-256 is pinned) --
# Tarball: https://dl.grafana.com/grafana/release/<version>/grafana_<version>_<build>_linux_amd64.tar.gz
# SHA-256: the same URL + .sha256, or the Grafana download page (Standalone Linux Binaries).

variable "grafana_version" {
  description = "Grafana release, monitoring VM (:3000)."
  type        = string
  default     = "13.3.2"
}

variable "grafana_build" {
  description = "Build number in the Grafana tarball name (13.3.2 -> 44555861735)."
  type        = string
  default     = "44555861735"
}

variable "grafana_sha256" {
  description = "SHA-256 of the linux_amd64 Grafana tarball for grafana_version + grafana_build."
  type        = string
  default     = "e6f06cf4ad96a4809294c2e78d3ebe6bc42a79bff36ffe35eefbe502fc19aa87"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.grafana_sha256))
    error_message = "grafana_sha256 must be 64 lowercase hex characters."
  }
}

# Lab only, like ssh_password. Grafana applies it only when it creates its DB on
# first start. If you change the password later (UI or `grafana cli admin
# reset-admin-password`), set this to match: monitoring_ready logs in with it.
variable "grafana_admin_password" {
  description = "Grafana admin password (user admin). Lab default admin/admin; Grafana offers to change it at first login."
  type        = string
  default     = "admin"

  validation {
    condition     = can(regex("^[A-Za-z0-9@#%+=:,._-]{5,}$", var.grafana_admin_password))
    error_message = "grafana_admin_password: at least 5 characters from A-Z a-z 0-9 @ # % + = : , . _ - (it is passed in a shell command)."
  }
}

variable "node_version" {
  description = "Node.js major version installed via NodeSource."
  type        = string
  default     = "24"
}

variable "mysql_repo_url" {
  description = "Git URL of the mysql repo, e.g. https://github.com/<org>/expense-mysql-v1.git"
  type        = string
}

variable "mysql_repo_ref" {
  description = "Git branch (or tag) to deploy."
  type        = string
  default     = "main"
}

variable "backend_repo_url" {
  description = "Git URL of the backend repo, e.g. https://github.com/<org>/expense-backend-v1.git"
  type        = string
}

variable "backend_repo_ref" {
  description = "Git branch (or tag) to deploy."
  type        = string
  default     = "main"
}

variable "frontend_repo_url" {
  description = "Git URL of the frontend repo, e.g. https://github.com/<org>/expense-frontend-v1.git"
  type        = string
}

variable "frontend_repo_ref" {
  description = "Git branch (or tag) to deploy."
  type        = string
  default     = "main"
}

variable "backend_extra_env" {
  description = "Extra env vars written as-is into /etc/expense/backend.env (e.g. ENABLE_DEBUG_API, DEBUG_TOKEN, METRICS_PORT). They override earlier values."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.backend_extra_env) : can(regex("^[A-Z_][A-Z0-9_]*$", k))])
    error_message = "backend_extra_env keys must be UPPER_SNAKE_CASE environment variable names."
  }
}

variable "db_name" {
  type    = string
  default = "expense"
}

variable "db_user" {
  description = "MySQL application user."
  type        = string
  default     = "expense"
}
