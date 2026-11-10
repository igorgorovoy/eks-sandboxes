# microVM-пул (nested virtualization, Firecracker/Kata) — третій стовпець бенчмарку.
# Історична альтернатива Nitro Sandboxes: див. абзац статті «чому вже не треба».
locals {
  # AL2023 managed node group вимагає MIME multipart; EKS змерджить це зі своїм nodeadm-конфігом.
  kvm_user_data = <<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -euo pipefail
    modprobe kvm_intel || true
    if [ -c /dev/kvm ]; then
      echo "nested-virt: /dev/kvm ready" | tee /var/log/kvm-check.log
    else
      echo "nested-virt: /dev/kvm MISSING" | tee /var/log/kvm-check.log >&2
    fi
    --//--
  EOT
}

resource "aws_launch_template" "microvm" {
  name_prefix = "${var.cluster_name}-microvm-"

  # Головне: вмикаємо VT-x для гостя (L1), щоб KVM міг запускати microVM (L2).
  cpu_options {
    nested_virtualization = "enabled"
  }

  # Агенти виконують недовірений код: hop limit 1 відрізає поди від IMDS.
  # Доступ до AWS для подів — через EKS Pod Identity.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(local.kvm_user_data)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "microvm" {
  cluster_name           = aws_eks_cluster.this.name
  node_group_name_prefix = "microvm-"
  node_role_arn          = aws_iam_role.mng_node.arn
  subnet_ids             = local.subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.sandbox_instance_type]

  launch_template {
    id      = aws_launch_template.microvm.id
    version = aws_launch_template.microvm.latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  labels = { "sandbox-runtime" = "microvm" }

  taint {
    key    = "sandbox"
    value  = "microvm"
    effect = "NO_SCHEDULE"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.mng_node]
}
