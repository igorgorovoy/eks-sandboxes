# ---------- Cluster IAM (Auto Mode) ----------
resource "aws_iam_role" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "AmazonEKSClusterPolicy",
    "AmazonEKSComputePolicy",
    "AmazonEKSBlockStoragePolicy",
    "AmazonEKSLoadBalancingPolicy",
    "AmazonEKSNetworkingPolicy",
  ])
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# ---------- Node IAM для Auto Mode нод ----------
resource "aws_iam_role" "auto_node" {
  name_prefix = "${var.cluster_name}-auto-node-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "auto_node" {
  for_each = toset([
    "AmazonEKSWorkerNodeMinimalPolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.auto_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# ---------- Cluster: Auto Mode (Nitro) + дві MNG (gVisor, microVM) ----------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Auto Mode: compute, storage і LB вмикаються лише разом
  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.auto_node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids              = local.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Managed-аддони потрібні лише для MNG-нод (gVisor). Auto Mode ноди мають усе вбудоване.
resource "aws_eks_addon" "core" {
  for_each = toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.value
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.gvisor]
}
