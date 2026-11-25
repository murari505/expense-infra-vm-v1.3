# expense-infra-vm-v1.3

One `terraform apply` brings up the 3-tier Expense app on EC2, reachable over
HTTPS at `https://expense.<your-domain>`, **with a complete monitoring stack**:
Prometheus scraping every exporter through EC2 service discovery, blackbox
probes of the public app and its DNS, and Grafana with its datasource and three
dashboards provisioned. The apply returns only when all of it works.
`terraform destroy` removes everything.

Built from `aiops-v2/expense-infra-vm-v1.2` (commit 86f7d45); v1.2 stays
unchanged for the earlier sessions. Ships as tag `session-NN` (TBD).

**What v1.3 adds to v1.2:**

| Area | v1.2 | v1.3 |
|---|---|---|
| Prometheus | Installed, default config (scrapes itself) | Config from the repo: EC2 SD jobs, blackbox jobs, Grafana and blackbox self-scrape; 15 d retention |
| Blackbox exporter | Not installed (`blackbox.yaml` unused) | Installed on the monitoring VM, :9115, modules from the repo |
| Grafana | Not installed | 13.3.2 on the monitoring VM, :3000, datasource + 3 dashboards provisioned |
| Swap | 2 GB `/swapfile` on `/` per VM | Removed: the AMI's 2 GB `RootVG-swapVol` is enough |
| Monitoring disk | 20 GB, `/` = 6 GB | 50 GB; userdata grows `/` to 16 GB and `/var` to 12 GB |
| Monitoring size | t3.micro | t3.small (Grafana 13 alone uses 200-300 MB) |
| Domains in config | hard-coded in the config files | Rendered from `var.domain_name` |
| Config changes | Edit on the VM by hand | Edit `config/` in the repo and apply: services reload, the VM is **not** replaced |

All VMs run the course AMI `Redhat-9-DevOps-Practice` (RHEL 9). It uses
**password SSH, no key pair**: user `ec2-user`, password `DevOps321` (practice
credentials, set by the `ssh_user` / `ssh_password` variables).

> **The ALB bills by the hour. Run `terraform destroy` at the end of every lab day.**
>
> v1, v1.2 and v1.3 create the same names (ALB, IAM role, Route53 records, VMs).
> Run only one of them at a time: destroy v1.2 before applying v1.3.

## Architecture

```
Internet ──HTTPS:443──▶ ALB  expense.<domain>  (ACM cert, HTTP→HTTPS redirect)
                          │ HTTP:80 (target group → frontend instance)
                          ▼
            expense-frontend   frontend.<domain>   nginx: React build, /api → backend.<domain>:8080
                          │                        + node_exporter :9100, nginx exporter :9113
                          ▼
            expense-backend    backend.<domain>    Node.js API (systemd), DB_HOST=mysql.<domain>
                          │                        + node_exporter :9100, app metrics :9101
                          ▼
            expense-mysql      mysql.<domain>      MySQL 8
                                                   + node_exporter :9100, mysqld_exporter :9104

            expense-monitoring (public IP)         Prometheus :9090 (config from config/)
                                                   blackbox_exporter :9115 (probes expense.<domain>
                                                     over HTTPS/HTTP, DNS via 8.8.8.8 and the VPC resolver)
                                                   Grafana :3000 (datasource + 3 dashboards)
                                                   + node_exporter :9100
                                                   discovers the VMs above via the EC2 API,
                                                   scrapes them over private IPs
```

**The app VMs reach each other only through Route53 names.** Terraform creates
an A record per tier in your public hosted zone, pointing at the VM's private
IP (TTL 60 s):

| Record | Used by |
|---|---|
| `mysql.<domain>` | backend (`DB_HOST`) |
| `backend.<domain>` | frontend nginx (`proxy_pass`) |
| `frontend.<domain>` | nobody in the app; handy for SSH and static scrape configs |

No VM's userdata contains another VM's IP. So:
- Replacing one VM (for example `-replace=aws_instance.backend`) replaces **only that
  VM**. Its record is updated in place and the others keep working.
- nginx re-resolves `backend.<domain>` at request time (VPC resolver, variable
  `proxy_pass`), so it follows a replaced backend within about a minute.
- The records resolve to private addresses, so they only work inside the VPC.
- These record names belong to this stack. Terraform overwrites them if they
  already exist, so don't use them for anything else in the same zone.

The ALB is the only public entry point for the app. It targets the frontend
instance directly (target groups take instances, not names).

The monitoring VM is created **last**, after the three app VMs and the ALB
(`depends_on`). That only orders creation: replacing an app VM later does not
replace the monitoring VM, so the Prometheus data survives app redeploys.

## Monitoring config as code

Userdata only **installs** Prometheus, blackbox_exporter and Grafana, each with
a minimal config so the service starts. Every real config file lives in
`config/`, which maps one-to-one onto the monitoring VM:

| In the repo | On the VM | Checked with | Then |
|---|---|---|---|
| `config/prometheus/prometheus.yml.tftpl` | `/etc/prometheus/prometheus.yml` | `promtool check config` | `systemctl reload prometheus` |
| `config/blackbox/blackbox.yml.tftpl` | `/etc/blackbox_exporter/blackbox.yml` | `blackbox_exporter --config.check` | `systemctl reload blackbox_exporter` |
| `config/grafana/grafana.ini.tftpl` | `/etc/grafana/grafana.ini` | - | restart grafana |
| `config/grafana/provisioning/**` | `/etc/grafana/provisioning/**` | YAML parses | restart grafana |
| `config/grafana/dashboards/*.json` | `/var/lib/grafana/dashboards/` | JSON parses | none (rescanned every 30 s) |

`terraform_data.monitoring_config` (`monitoring-config.tf`) renders the
`.tftpl` files with `templatefile()` (domain, region, VPC resolver and Grafana
password come from variables: nothing is hard-coded), uploads everything over
SSH, then runs `templates/apply-monitoring-config.sh` on the VM. That script
checks **every** file first and stops at the first failure without touching the
running config, then installs only the files that changed and reloads or
restarts only the services they belong to.

Its trigger is the SHA-256 of every config file plus the monitoring instance
id. So to change the monitoring config:

```bash
vi config/prometheus/prometheus.yml.tftpl    # or a dashboard JSON, ...
terraform apply                              # re-runs only monitoring_config + monitoring_ready
```

The VM is not replaced and the Prometheus history stays. A new dashboard is
just a new `config/grafana/dashboards/<name>.json` with a fixed `uid` and
datasource `{"type": "prometheus", "uid": "prometheus"}`. Don't edit the files
on the VM: the next apply that changes `config/` overwrites them.

| Prometheus job | Found by | Port | Targets |
|---|---|---|---|
| `prometheus` | static `localhost` | 9090 | 1 |
| `node` | EC2 SD, `Monitoring=true`, `Project=expense` | 9100 | 4 |
| `nginx` | EC2 SD, keep `Tier=frontend` | 9113 | 1 |
| `backend` | EC2 SD, keep `Tier=backend` | 9101 | 1 |
| `mysql` | EC2 SD, keep `Tier=db` | 9104 | 1 |
| `blackbox_exporter` | static `localhost` | 9115 | 1 |
| `grafana` | static `localhost` | 3000 | 1 |
| `blackbox_http` | static, via `localhost:9115` | - | 3: `https://expense.<domain>/` (`probe=alb`), `/api/health/ready` (`app_ready`), `http://` to `https://` redirect (`alb_redirect`) |
| `blackbox_dns` | static, via `localhost:9115` | - | 5: `expense.<domain>` via 8.8.8.8 and via the VPC resolver; `frontend`/`backend`/`mysql.<domain>` via the VPC resolver |

| Dashboard (uid) | Shows |
|---|---|
| `expense-panels` | 7 panel types on the backend's `http_request_duration_seconds`: stat, gauge, bar gauge, time series, table, heatmap, state timeline |
| `node-use` | USE per host: CPU %, memory %, disk % per mount, hours until disk full, load 1/5/15, network RX/TX, disk I/O busy; variables `tier`, `instance` |
| `blackbox-probes` | probe up/down, certificate days left, HTTP status, DNS lookup time, HTTP request phases |

All three are in the Grafana folder **Expense App**.

## Tags for EC2 service discovery

Every instance gets these tags (`Project=expense` comes from the provider's
`default_tags`, like `Environment=lab` and `ManagedBy=terraform`):

| Instance | `Monitoring` | `Project` | `Tier` | `Component` |
|---|---|---|---|---|
| `expense-mysql` | `true` | `expense` | `db` | `mysql` |
| `expense-backend` | `true` | `expense` | `backend` | `expense-service` |
| `expense-frontend` | `true` | `expense` | `frontend` | `nginx` |
| `expense-monitoring` | `true` | `expense` | `monitoring` | `prometheus` |

In `ec2_sd_configs` they appear as `__meta_ec2_tag_Monitoring`,
`__meta_ec2_tag_Project`, `__meta_ec2_tag_Tier`, `__meta_ec2_tag_Component`
and `__meta_ec2_tag_Name` (tag keys are case-sensitive). They are also usable
as server-side `filters` (`tag:Monitoring`, `tag:Tier`, …).

`prometheus.yml.tftpl` filters on `tag:Monitoring=true` and
`tag:Project=<project>` server-side, then keeps per job on `Tier`. Credentials:
none in the file; the instance role `expense-prometheus` allows
`ec2:DescribeInstances` and `ec2:DescribeAvailabilityZones`.

## What gets created

74 resources: 63 in AWS, 11 Terraform-only (4 passwords, 5 readiness checks, monitoring config, monitoring readiness).
Every taggable AWS resource gets `Project=expense`, `Environment=lab`,
`ManagedBy=terraform`, plus `Name` and `Tier`.

| Area | Terraform resource | AWS name / value | Tier tag | Count |
|---|---|---|---|---|
| **Network** | `aws_vpc.main` | `expense-vpc` (10.0.0.0/16, DNS support on) | `network` | 1 |
| | `aws_subnet.public["a"]`, `["b"]` | `expense-public-a` (10.0.1.0/24), `expense-public-b` (10.0.2.0/24), two AZs | `network` | 2 |
| | `aws_internet_gateway.main` | `expense-igw` | `network` | 1 |
| | `aws_route_table.public` | `expense-public-rt` (0.0.0.0/0 → IGW) | `network` | 1 |
| | `aws_route_table_association.public` | both subnets → `expense-public-rt` | | 2 |
| **Security groups** | `aws_security_group.alb` | `expense-alb-sg` | `edge` | 1 |
| | `aws_security_group.frontend` | `expense-frontend-sg` | `frontend` | 1 |
| | `aws_security_group.backend` | `expense-backend-sg` | `backend` | 1 |
| | `aws_security_group.mysql` | `expense-mysql-sg` | `db` | 1 |
| | `aws_security_group.monitoring` | `expense-monitoring-sg` | `monitoring` | 1 |
| | `aws_vpc_security_group_ingress_rule.*` | ALB 80, 443 from anywhere; frontend 80 from ALB SG; backend 8080 from frontend SG; mysql 3306 from backend SG; 22 from `admin_cidr` (your looked-up IP) on each of the 4 VMs | | 9 |
| | `aws_vpc_security_group_ingress_rule.monitoring` | 9100 on every VM, 9113 frontend, 9101 backend, 9104 mysql, 9090 monitoring; each from `admin_cidr`, the VPC CIDR and every `monitoring_cidrs` entry | | 16 (+8 per `monitoring_cidrs` entry) |
| | `aws_vpc_security_group_ingress_rule.monitoring_admin` | Grafana 3000 and blackbox_exporter 9115 on the monitoring VM, from `admin_cidr` **only** | | 2 |
| | `aws_vpc_security_group_egress_rule.all` | all outbound, one per SG | | 5 |
| **IAM** | `aws_iam_role.prometheus` | `expense-prometheus`, assumable by EC2 | `monitoring` | 1 |
| | `aws_iam_role_policy.prometheus_ec2_sd` | inline: `ec2:DescribeInstances`, `ec2:DescribeAvailabilityZones` | | 1 |
| | `aws_iam_instance_profile.prometheus` | `expense-prometheus`, attached to the monitoring VM | `monitoring` | 1 |
| **VMs** | `aws_instance.frontend` | `expense-frontend`, `t3.micro`, 20 GB gp3, nginx + React build, node + nginx exporters | `frontend` | 1 |
| | `aws_instance.backend` | `expense-backend`, `t3.micro`, 20 GB gp3, Node.js API, node_exporter | `backend` | 1 |
| | `aws_instance.mysql` | `expense-mysql`, `t3.micro`, 20 GB gp3, MySQL 8, node + mysqld exporters | `db` | 1 |
| | `aws_instance.monitoring` | `expense-monitoring`, `t3.small`, 50 GB gp3, Prometheus, blackbox_exporter, Grafana, node_exporter | `monitoring` | 1 |
| **Load balancer** | `aws_lb.main` | `expense-alb` (internet-facing, both subnets) | `edge` | 1 |
| | `aws_lb_target_group.frontend` | `expense-frontend-tg` (HTTP 80, health check `/healthz`) | `edge` | 1 |
| | `aws_lb_target_group_attachment.frontend` | frontend instance → target group | | 1 |
| | `aws_lb_listener.https` | 443, TLS 1.3/1.2 policy, forwards to the target group | `edge` | 1 |
| | `aws_lb_listener.http` | 80, 301 redirect to HTTPS | `edge` | 1 |
| **TLS** | `aws_acm_certificate.app` | certificate for `expense.<domain>` | `edge` | 1 |
| | `aws_route53_record.cert_validation` | ACM DNS-validation CNAME | | 1 |
| | `aws_acm_certificate_validation.app` | waits until ACM issues the certificate | | 1 |
| **DNS** (in your existing zone) | `aws_route53_record.app` | `expense.<domain>` → ALB (alias) | | 1 |
| | `aws_route53_record.frontend` | `frontend.<domain>` → frontend private IP | | 1 |
| | `aws_route53_record.backend` | `backend.<domain>` → backend private IP | | 1 |
| | `aws_route53_record.mysql` | `mysql.<domain>` → mysql private IP | | 1 |
| **Secrets** (Terraform only, not in AWS) | `random_password.mysql_root`, `.db_app`, `.jwt_secret`, `.mysql_exporter` | MySQL root password, app DB password, JWT secret, mysqld_exporter's MySQL password | | 4 |
| **Readiness** (Terraform only) | `terraform_data.vm_ready["frontend"/"backend"/"mysql"/"monitoring"]` | SSH in, wait for setup, fail on `FAILURE` | | 4 |
| | `terraform_data.app_ready` | `https://expense.<domain>/api/health/ready` must answer 200 | | 1 |
| **Monitoring config** (Terraform only) | `terraform_data.monitoring_config` | push `config/`, check, install, reload | | 1 |
| | `terraform_data.monitoring_ready` | 18 targets up, every probe succeeds, Grafana datasource OK, 3 dashboards present | | 1 |

**Read, not created:** the Route53 hosted zone (`data.aws_route53_zone`), the
AMI (`data.aws_ami.joindevops`) and the availability zones.

**Not created on purpose:** no NAT gateway, no EC2 key pair (password SSH), no
Route53 record for Prometheus or Grafana (open them by public IP), no
Alertmanager, recording or alerting rules, no logs or traces, no TCP probe to
MySQL (its SG does not allow the monitoring VM on 3306), no Auto Scaling group,
no remote state.

**What costs money while it runs:** the ALB (hourly plus LCU), three t3.micro
instances and one t3.small (about twice a t3.micro's hourly price), three 20 GB
and one 50 GB gp3 volumes, and the public IPv4 addresses (ALB and instances). Route53 queries are cents. ACM certificates and IAM are free.

## Prerequisites

- AWS credentials configured (`aws sts get-caller-identity` works), allowed to
  create IAM roles and instance profiles (new in v1.2).
- A **Route53 public hosted zone** for your domain, already delegated.
- Terraform ≥ 1.6.
- No SSH key needed: the course AMI uses `ec2-user` / `DevOps321`.
- The three app repos reachable over HTTPS (public), with the code on `main`.
- The VMs download the exporters and Prometheus from GitHub releases, and
  Grafana from `dl.grafana.com` (they have public IPs and full outbound access).

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in domain, repo URLs/refs
terraform init
terraform apply
```

**`admin_cidr` is looked up, not typed.** Leave it unset and every plan/apply
reads this machine's public IP from `https://checkip.amazonaws.com` (the
`hashicorp/http` provider) and allows `<ip>/32` for SSH, Prometheus, Grafana,
blackbox and the exporters (`terraform output admin_cidr` shows it). If your IP
changes, the next `terraform apply` replaces just those security group rules,
nothing else. Set `admin_cidr = "<cidr>"` only to pin a fixed range (an office
network) or when the lookup can't work (HTTPS proxy, VPN with a different exit
IP than your browser).

Takes about 15–20 minutes. Apply finishes in this order:
1. Network, security groups, IAM role, certificate (validated through Route53).
2. `mysql` VM → `mysql.<domain>` → `backend` VM → `backend.<domain>` →
   `frontend` VM. Each VM waits for its upstream's record to exist first:
   a lookup of a name that doesn't exist yet would be cached as "no such name"
   for up to 15 minutes.
3. `monitoring` VM, once the three app VMs and the ALB exist. Its userdata
   grows the disk, then installs node_exporter, Prometheus, blackbox_exporter
   and Grafana.
4. Readiness: per VM, SSH in, wait for setup, and fail if
   `/var/log/expense/setup.log` has a `FAILURE`. Each exporter must answer with
   real data (`node_load1`, `mysql_up 1`, `nginx_up 1`, the backend's
   `expense_backend_build_info`, Prometheus `/-/ready`).
5. `monitoring_config`: render `config/`, upload it, check, install, reload.
6. End to end: from the frontend VM, `https://expense.<domain>/api/health/ready`
   must answer 200 within about 5 minutes, or the apply fails.
7. `monitoring_ready`: on the monitoring VM, every 10 s for up to 5 minutes
   (EC2 SD refreshes every 60 s): all 18 targets up, `min(probe_success) == 1`,
   the Grafana datasource healthy and the 3 dashboards present; otherwise the
   apply fails and prints the last check.

Outputs: `app_url`, `prometheus_url`, `grafana_url`, `blackbox_url`,
`ssh_commands`, `tier_hostnames`, `private_ips`, `instance_tags`, and
(sensitive) `grafana_admin_password`, `db_password`, `mysql_root_password`,
`jwt_secret`, `mysql_exporter_password`:

```bash
terraform output prometheus_url    # http://<public ip>:9090, from admin_cidr only
terraform output grafana_url       # http://<public ip>:3000, from admin_cidr only
terraform output blackbox_url      # http://<public ip>:9115, from admin_cidr only
terraform output ssh_commands      # ssh ec2-user@<public ip>, password DevOps321
terraform output -raw db_password
```

**Grafana login:** `admin` / `admin` (lab only, like the SSH password); Grafana
offers to change it at the first login. The password in `grafana.ini` is only
applied when Grafana creates its database on first start. If you change it (in
the UI, or with
`sudo -u grafana /opt/grafana/bin/grafana cli --homepath /opt/grafana --config /etc/grafana/grafana.ini admin reset-admin-password <new>`),
set `grafana_admin_password = "<new>"` in `terraform.tfvars` too:
`monitoring_ready` logs in with it.

Then put load on the app so the dashboards fill: see [loadtest/README.md](loadtest/README.md).

## Deploy new app code

Each VM clones its repo's `main` branch (`*_repo_ref`) once, when it is
created. New commits on `main` are **not** picked up automatically: Terraform
only sees that `"main"` hasn't changed. To redeploy a tier with the latest
`main`, rebuild just that VM:

```bash
terraform apply -replace=aws_instance.backend    # or .frontend / .mysql
```

Its Route53 record follows the new private IP and the other VMs are untouched.
Service discovery picks up the new instance on its next refresh (60 s by
default); the old one disappears from the targets. Counters on the new VM start
from 0, which `rate()` / `increase()` handle as a reset.

Changing a `*_repo_ref` to another branch (or tag) and applying does the same.
So does changing an exporter, Prometheus or Grafana version variable: it
re-renders that VM's userdata, which replaces the VM (on the monitoring VM, that
loses the Prometheus history). Monitoring **config** changes never do that: see
[Monitoring config as code](#monitoring-config-as-code).

Extra backend settings go in `backend_extra_env` (written as-is into
`/etc/expense/backend.env`, overriding earlier values):

```hcl
backend_extra_env = {
  ENABLE_DEBUG_API = "true"
  DEBUG_TOKEN      = "change-me-please"
}
```

The backend env file always gets `APP_REF=<backend_repo_ref>`, which the app
reports in `expense_backend_build_info`. If you set `METRICS_PORT` here, the
security group and the setup check follow it.

## On the VMs

| | frontend | backend | mysql | monitoring |
|---|---|---|---|---|
| Hostname | `expense-frontend` | `expense-backend` | `expense-mysql` | `expense-monitoring` |
| App directory | `/opt/expense/frontend` (build), `/usr/share/nginx/html` (served) | `/opt/expense/backend` | `/opt/expense/mysql` (migrations) | |
| Service | `nginx` | `expense-backend` (user `expense`) | `mysqld` | `prometheus`, `blackbox_exporter`, `grafana` (each its own user) |
| Config | `/etc/nginx/conf.d/expense.conf` | `/etc/expense/backend.env` (600) | `/etc/my.cnf.d/zz-expense.cnf` | `/etc/prometheus`, `/etc/blackbox_exporter`, `/etc/grafana` (from `config/`) |
| Data | | | | `/var/lib/prometheus`, `/var/lib/grafana` |
| Exporters | `node_exporter`, `nginx_exporter` | `node_exporter` | `node_exporter`, `mysqld_exporter` | `node_exporter` |
| Setup log | `/var/log/expense/setup.log` | same | same | same, plus `/var/log/expense/monitoring-config.log` |
| Disk | 20 GB | 20 GB | 20 GB | 50 GB: `/` 16 GB, `/var` 12 GB |
| Swap | the AMI's `RootVG-swapVol`, 2 GB | same | same | same |

Exporters and Prometheus come from the GitHub release tarballs, checked
against the release's SHA-256 checksums file. Grafana publishes no checksums
file, so its SHA-256 is pinned in `grafana_sha256`. All are laid out like the
manual scripts in `docs/` and the Grafana manual install doc:

```
/opt/<name>-<version>/   the release, owned by system user <name>
/opt/<name>              symlink to it; the systemd unit runs /opt/<name>/...
```

| Port | What | VM | Version variable | Checked at setup |
|---|---|---|---|---|
| 9100 | node_exporter | all | `node_exporter_version` (1.12.1) | `node_load1` present |
| 9101 | backend app metrics (built into the app) | backend | – | `expense_backend_build_info` present |
| 9104 | mysqld_exporter | mysql | `mysqld_exporter_version` (0.21.0) | `mysql_up 1` |
| 9113 | NGINX Prometheus exporter | frontend | `nginx_exporter_version` (1.5.3) | `nginx_up 1` |
| 9090 | Prometheus | monitoring | `prometheus_version` (3.16.0) | `/-/ready` |
| 9115 | blackbox_exporter | monitoring | `blackbox_exporter_version` (0.29.1) | `blackbox_exporter_build_info` present |
| 3000 | Grafana | monitoring | `grafana_version` (13.3.2), `grafana_build` (44555861735), `grafana_sha256` | `/api/health` shows `"database": "ok"` |

Details:
- **mysqld_exporter** logs in as `'exporter'@'127.0.0.1'` (`PROCESS`,
  `REPLICATION CLIENT`, `SELECT`, max 3 connections), password from
  `random_password.mysql_exporter`, stored in `/etc/mysqld_exporter/.my.cnf`
  (600).
- **nginx exporter** reads `http://127.0.0.1:8081/stub_status`, a separate
  nginx server bound to localhost only (`/etc/nginx/conf.d/stub_status.conf`,
  `access_log off`). Each scrape still adds 1 to nginx's request counter, as
  do the ALB health checks.
- Monitoring ports are open from `admin_cidr`, the VPC CIDR (10.0.0.0/16) and
  any `monitoring_cidrs`. From your machine:
  `curl http://<public ip>:9100/metrics`. Grafana (3000) and blackbox_exporter
  (9115) are open from `admin_cidr` only.
- firewalld is inactive on this AMI. If it is running, the scripts open each
  port there too.

## Destroy

```bash
terraform destroy
```

Removes everything, including the Route53 records and the IAM role it created.
The hosted zone itself is untouched.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Apply fails at `terraform_data.vm_ready["<tier>"]` | The output shows the tail of that VM's `setup.log`. SSH in: `sudo less /var/log/expense/setup.log`, `sudo cloud-init status --long` |
| `download ... FAILURE` / `verify SHA-256 ... FAILURE` | The version variable names a release that doesn't exist, or GitHub was unreachable. Check the URL in the log |
| `... answers on :<port> ... FAILURE` | `systemctl status <name>`, `journalctl -u <name> -n 50`. mysqld_exporter: `mysql_up 0` means its login failed. nginx exporter: `curl http://127.0.0.1:8081/stub_status` |
| `clone ... FAILURE` | The repo URL is wrong or private, or the `*_repo_ref` branch doesn't exist on GitHub |
| Backend never ready | On the backend: `journalctl -u expense-backend -n 100`; `getent hosts mysql.<domain>`; on mysql: `systemctl status mysqld` |
| 502 from the app | On the frontend: `getent hosts backend.<domain>`, `curl -v http://backend.<domain>:8080/api/health/live`, `sudo tail /var/log/nginx/error.log` |
| Apply fails at `app_ready` | DNS or the ALB: `dig expense.<domain>`, target group health in the console |
| EC2 SD finds nothing | Prometheus log: `journalctl -u prometheus -n 50` (`UnauthorizedOperation` = role not attached; check `region`). Status → Service Discovery in the UI shows the discovered labels before relabelling |
| Apply fails at `monitoring_config` | The output names the failed check (`promtool check config`, `--config.check`, YAML/JSON parse). Nothing was installed; fix the file in `config/` and apply again. On the VM: `sudo less /var/log/expense/monitoring-config.log` |
| Apply fails at `monitoring_ready` | The last check lists each target that is not up with its `lastError`, the failing probes, the datasource health and missing dashboards. Prometheus: Status > Targets; the blackbox page (`blackbox_url`) shows each probe's debug log |
| `GROW_DISK` / `lvextend` fails | `monitoring_volume_size` too small (40 or more), or the AMI's LVM layout changed: `lsblk`, `sudo vgs`, `sudo lvs` |
| Grafana login fails / `monitoring_ready` gets 401 | The admin password was changed: set `grafana_admin_password` to match |
| Certificate validation hangs | The hosted zone isn't the one your registrar delegates to (NS records mismatch) |
| `Error: no matching Route 53 Hosted Zone` | `domain_name` must be an existing public hosted zone in this account |
