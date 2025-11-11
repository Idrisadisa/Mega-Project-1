output "cluster_id" {
  value = aws_eks_cluster.powerdevops.id
}

output "node_group_id" {
  value = aws_eks_node_group.powerdevops.id
}

output "vpc_id" {
  value = aws_vpc.powerdevops_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.powerdevops_subnet[*].id
}

