terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment after bootstrapping the S3 backend
  # backend "s3" {
  #   bucket         = "hybrid-k8s-tfstate"
  #   key            = "cloud/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "hybrid-k8s-tfstate-lock"
  # }
}

provider "aws" {
  region = var.aws_region
}
