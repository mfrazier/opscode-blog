output "cloudfront_distribution_id" {
  description = "Add to GitHub Actions secrets as CLOUDFRONT_DISTRIBUTION_ID"
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain" {
  description = "CloudFront domain name (useful for debugging)"
  value       = aws_cloudfront_distribution.site.domain_name
}

output "s3_bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.site.bucket
}

output "github_actions_role_arn" {
  description = "Add to GitHub Actions secrets as AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}
