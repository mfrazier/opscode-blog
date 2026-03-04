terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "opscode-terraform-state"
    region         = "us-east-1"
    key            = "state/opscode-blog/terraform.tfstate"
    encrypt        = true
    dynamodb_table = "opscode-tf-state-lock"
  }
}

# Single provider — no alias needed.
# ACM uses region = "us-east-1" directly on the resource (AWS provider v6 feature).
provider "aws" {
  region = var.aws_region
}
