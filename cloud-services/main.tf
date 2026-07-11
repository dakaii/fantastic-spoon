# Cloud Services — standby cluster, backup storage, and witness infrastructure

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "standby" {
  key_name   = "${var.project_name}-standby"
  public_key = var.ssh_public_key
}

resource "aws_vpc" "standby" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "standby" {
  vpc_id = aws_vpc.standby.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "standby" {
  vpc_id                  = aws_vpc.standby.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "${var.project_name}-subnet"
  }
}

resource "aws_route_table" "standby" {
  vpc_id = aws_vpc.standby.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.standby.id
  }

  tags = {
    Name = "${var.project_name}-rt"
  }
}

resource "aws_route_table_association" "standby" {
  subnet_id      = aws_subnet.standby.id
  route_table_id = aws_route_table.standby.id
}

resource "aws_security_group" "standby" {
  name        = "${var.project_name}-standby-sg"
  description = "Standby k3s nodes"
  vpc_id      = aws_vpc.standby.id

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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-standby-sg"
  }
}

resource "aws_instance" "standby" {
  count                       = var.standby_node_count
  ami                         = data.aws_ami.ubuntu_arm.id
  instance_type               = var.standby_instance_type
  key_name                    = aws_key_pair.standby.key_name
  subnet_id                   = aws_subnet.standby.id
  vpc_security_group_ids      = [aws_security_group.standby.id]
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/cloud-init/node.yaml.tftpl", {
    hostname  = "${var.project_name}-standby-${count.index + 1}"
    node_role = count.index == 0 ? "server" : "agent"
  }))

  root_block_device {
    volume_size = var.node_disk_gb
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-standby-${count.index + 1}"
    Role    = count.index == 0 ? "server" : "agent"
    Cluster = "standby"
  }
}

resource "aws_lb" "standby" {
  name               = "${var.project_name}-standby-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.standby.id]

  tags = {
    Name = "${var.project_name}-standby-nlb"
  }
}

resource "aws_lb_target_group" "standby_https" {
  name     = "${var.project_name}-standby-tg"
  port     = 30443
  protocol = "TCP"
  vpc_id   = aws_vpc.standby.id

  health_check {
    protocol = "TCP"
    port     = "30443"
  }
}

resource "aws_lb_target_group_attachment" "standby_workers" {
  for_each = {
    for idx, inst in aws_instance.standby :
    inst.tags.Name => inst
    if inst.tags.Role == "agent"
  }

  target_group_arn = aws_lb_target_group.standby_https.arn
  target_id        = each.value.id
  port             = 30443
}

resource "aws_lb_listener" "standby_https" {
  load_balancer_arn = aws_lb.standby.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.standby_https.arn
  }
}

# --- Backup Storage ---

resource "aws_s3_bucket" "backups" {
  bucket = "${var.project_name}-backups-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-backups"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM for Velero ---

resource "aws_iam_user" "velero" {
  name = "${var.project_name}-velero"
}

resource "aws_iam_user_policy" "velero" {
  name = "${var.project_name}-velero-s3"
  user = aws_iam_user.velero.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backups.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "velero" {
  user = aws_iam_user.velero.name
}

data "aws_caller_identity" "current" {}
