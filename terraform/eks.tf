module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    main = {
      name           = "${var.project_name}-node-group"
      instance_types = [var.node_instance_type]
      
      iam_role_name            = "${var.project_name}-node-role"
      iam_role_use_name_prefix = false
	

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        Environment = var.environment
        Project     = var.project_name
      }

      tags = {
        Name        = "${var.project_name}-node-group"
        Environment = var.environment
      }
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  tags = {
    Name        = var.cluster_name
    Environment = var.environment
    Project     = var.project_name
     Name        = "${var.project_name}-node-group"
     Environment = var.environment
     "k8s.io/cluster-autoscaler/enabled"             = "true"
     "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
}

