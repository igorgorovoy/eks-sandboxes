output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }

# Кожен пул у своєму ресурсі — for_each тут нема.
output "gvisor_nodegroup" { value = aws_eks_node_group.gvisor.node_group_name }
output "microvm_nodegroup" { value = aws_eks_node_group.microvm.node_group_name }
output "microvm_launch_template" {
  value = aws_launch_template.microvm.id
}

output "private_subnet_ids" { value = local.subnet_ids }
output "nat_gateway_id" { value = aws_nat_gateway.this.id }
