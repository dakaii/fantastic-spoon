terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "primary" {
  key_name   = "${var.project_name}-primary"
  public_key = var.ssh_public_key
}

resource "aws_vpc" "primary" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-primary-vpc"
  }
}

resource "aws_internet_gateway" "primary" {
  vpc_id = aws_vpc.primary.id

  tags = {
    Name = "${var.project_name}-primary-igw"
  }
}

resource "aws_subnet" "primary" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.primary.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-primary-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "primary" {
  vpc_id = aws_vpc.primary.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.primary.id
  }

  tags = {
    Name = "${var.project_name}-primary-rt"
  }
}

resource "aws_route_table_association" "primary" {
  count          = length(aws_subnet.primary)
  subnet_id      = aws_subnet.primary[count.index].id
  route_table_id = aws_route_table.primary.id
}

resource "aws_security_group" "primary" {
  name        = "${var.project_name}-primary-sg"
  description = "Primary k3s cluster nodes"
  vpc_id      = aws_vpc.primary.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "k3s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NodePort range"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Inter-node k3s"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-primary-sg"
  }
}

locals {
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      name = "${var.project_name}-cp-${i + 1}"
      role = "server"
      az   = var.availability_zones[i % length(var.availability_zones)]
    }
  ]

  worker_nodes = [
    for i in range(var.worker_count) : {
      name = "${var.project_name}-worker-${i + 1}"
      role = "agent"
      az   = var.availability_zones[i % length(var.availability_zones)]
    }
  ]

  all_nodes = concat(local.control_plane_nodes, local.worker_nodes)
}

resource "aws_instance" "primary" {
  for_each = { for node in local.all_nodes : node.name => node }

  ami                         = data.aws_ami.ubuntu_arm.id
  instance_type               = each.value.role == "server" ? var.control_plane_instance_type : var.worker_instance_type
  key_name                    = aws_key_pair.primary.key_name
  subnet_id                   = [for s in aws_subnet.primary : s.id if s.availability_zone == each.value.az][0]
  vpc_security_group_ids      = [aws_security_group.primary.id]
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    hostname   = each.key
    node_role  = each.value.role
    node_index = index([for n in local.all_nodes : n.name], each.key) + 1
  }))

  root_block_device {
    volume_size = var.node_disk_gb
    volume_type = "gp3"
  }

  tags = {
    Name    = each.key
    Role    = each.value.role
    Cluster = "primary"
  }
}

resource "aws_lb" "primary" {
  name               = "${var.project_name}-primary-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.primary[*].id

  tags = {
    Name = "${var.project_name}-primary-nlb"
  }
}

resource "aws_lb_target_group" "primary_https" {
  name     = "${var.project_name}-primary-tg"
  port     = 30443
  protocol = "TCP"
  vpc_id   = aws_vpc.primary.id

  health_check {
    protocol = "TCP"
    port     = "30443"
  }
}

resource "aws_lb_target_group_attachment" "primary_workers" {
  for_each = {
    for name, inst in aws_instance.primary :
    name => inst
    if inst.tags.Role == "agent"
  }

  target_group_arn = aws_lb_target_group.primary_https.arn
  target_id        = each.value.id
  port             = 30443
}

resource "aws_lb_listener" "primary_https" {
  load_balancer_arn = aws_lb.primary.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.primary_https.arn
  }
}

resource "aws_lb_listener" "primary_http" {
  load_balancer_arn = aws_lb.primary.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.primary_https.arn
  }
}
