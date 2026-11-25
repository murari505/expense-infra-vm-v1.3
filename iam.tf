# Instance role for the monitoring VM: Prometheus ec2_sd_configs calls the EC2
# API with these credentials (from instance metadata, nothing to configure in
# prometheus.yml). Read-only, and only the two calls service discovery makes:
#   ec2:DescribeInstances          the instances, their IPs and tags
#   ec2:DescribeAvailabilityZones  maps each instance's AZ to its AZ ID

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "prometheus_ec2_sd" {
  statement {
    sid       = "PrometheusEC2ServiceDiscovery"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"] # Describe* calls cannot be scoped to resources
  }
}

resource "aws_iam_role" "prometheus" {
  name               = "${var.project}-prometheus"
  description        = "Prometheus on ${var.project}-monitoring: EC2 service discovery (read-only)"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${var.project}-prometheus", Tier = "monitoring" }
}

resource "aws_iam_role_policy" "prometheus_ec2_sd" {
  name   = "ec2-service-discovery"
  role   = aws_iam_role.prometheus.id
  policy = data.aws_iam_policy_document.prometheus_ec2_sd.json
}

resource "aws_iam_instance_profile" "prometheus" {
  name = "${var.project}-prometheus"
  role = aws_iam_role.prometheus.name
  tags = { Name = "${var.project}-prometheus", Tier = "monitoring" }
}
