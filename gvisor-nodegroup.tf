# ---------- Shared IAM for both MNG pools (gvisor + microvm) ----------
resource "aws_iam_role" "mng_node" {
  name_prefix = "${var.cluster_name}-mng-node-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mng_node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.mng_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "gvisor" {
  name_prefix = "${var.cluster_name}-gvisor-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # agents must not reach node IMDS
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

  # MIME: NodeConfig (runsc in containerd) + gVisor install script
  user_data = base64encode(file("${path.module}/gvisor.mime"))

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "gvisor" {
  cluster_name           = aws_eks_cluster.this.name
  node_group_name_prefix = "gvisor-"
  node_role_arn          = aws_iam_role.mng_node.arn
  subnet_ids             = local.subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.sandbox_instance_type]

  launch_template {
    id      = aws_launch_template.gvisor.id
    version = aws_launch_template.gvisor.latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = 3
  }

  labels = { "sandbox-runtime" = "gvisor" }

  taint {
    key    = "sandbox"
    value  = "gvisor"
    effect = "NO_SCHEDULE"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.mng_node,
    aws_eks_addon.core,
  ]
}
