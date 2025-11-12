provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "powerdevops_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "powerdevops-vpc"
  }
}

resource "aws_subnet" "powerdevops_subnet" {
  count = 2
  vpc_id                  = aws_vpc.powerdevops_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.powerdevops_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["us-east-1a", "us-east-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "powerdevops-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "powerdevops_igw" {
  vpc_id = aws_vpc.powerdevops_vpc.id

  tags = {
    Name = "powerdevops-igw"
  }
}

resource "aws_route_table" "powerdevops_route_table" {
  vpc_id = aws_vpc.powerdevops_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.powerdevops_igw.id
  }

  tags = {
    Name = "powerdevops-route-table"
  }
}

resource "aws_route_table_association" "powerdevops_association" {
  count          = 2
  subnet_id      = aws_subnet.powerdevops_subnet[count.index].id
  route_table_id = aws_route_table.powerdevops_route_table.id
}

resource "aws_security_group" "powerdevops_cluster_sg" {
  vpc_id = aws_vpc.powerdevops_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "powerdevops-cluster-sg"
  }
}

resource "aws_security_group" "powerdevops_node_sg" {
  vpc_id = aws_vpc.powerdevops_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "powerdevops-node-sg"
  }
}

resource "aws_eks_cluster" "powerdevops" {
  name     = "powerdevops-cluster"
  role_arn = aws_iam_role.powerdevops_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.powerdevops_subnet[*].id
    security_group_ids = [aws_security_group.powerdevops_cluster_sg.id]
  }
}

data "aws_eks_cluster" "this" {
  name       = aws_eks_cluster.powerdevops.name
  depends_on = [aws_eks_cluster.powerdevops]
}

data "tls_certificate" "eks" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name = "powerdevops-ebs-csi-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          # The EKS add-on uses this SA by default:
          # namespace: kube-system, name: ebs-csi-controller-sa
          "${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa_policy" {
  role       = aws_iam_role.ebs_csi_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_eks_addon_version" "ebs" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = data.aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name  = aws_eks_cluster.powerdevops.name
  addon_name    = "aws-ebs-csi-driver"
  # Optional but recommended to stop Terraform re-install warnings:
  addon_version = data.aws_eks_addon_version.ebs.version

  # CRITICAL: give the add-on its IAM role
  service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.powerdevops,            # ensure nodes are ready to schedule
    aws_iam_openid_connect_provider.eks,       # IRSA provider exists
    aws_iam_role_policy_attachment.ebs_csi_irsa_policy
  ]
}

resource "aws_eks_node_group" "powerdevops" {
  cluster_name    = aws_eks_cluster.powerdevops.name
  node_group_name = "powerdevops-node-group"
  node_role_arn   = aws_iam_role.powerdevops_node_group_role.arn
  subnet_ids      = aws_subnet.powerdevops_subnet[*].id

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  instance_types = ["t2.medium"]

  remote_access {
    ec2_ssh_key = var.ssh_key_name
    source_security_group_ids = [aws_security_group.powerdevops_node_sg.id]
  }
}

resource "aws_iam_role" "powerdevops_cluster_role" {
  name = "powerdevops-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "powerdevops_cluster_role_policy" {
  role       = aws_iam_role.powerdevops_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "powerdevops_node_group_role" {
  name = "powerdevops-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "powerdevops_node_group_role_policy" {
  role       = aws_iam_role.powerdevops_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "powerdevops_node_group_cni_policy" {
  role       = aws_iam_role.powerdevops_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "powerdevops_node_group_registry_policy" {
  role       = aws_iam_role.powerdevops_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}



