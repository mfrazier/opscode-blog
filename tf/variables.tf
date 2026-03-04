variable "aws_region" {
  description = "Primary AWS region for S3 and most resources"
  type        = string
  default     = "us-west-2"
}

variable "domain_name" {
  description = "Root domain — must already exist as a Route 53 hosted zone"
  type        = string
  default     = "opscode.io"
}

variable "www_domain_name" {
  description = "www subdomain"
  type        = string
  default     = "www.opscode.io"
}

variable "github_repo" {
  description = "GitHub repo in owner/name format for OIDC trust policy"
  type        = string
  default     = "mfrazier/opscode-blog"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "opscode-blog"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
