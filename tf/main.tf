# ── Route 53: look up existing hosted zone ──────────────────────────────────

data "aws_route53_zone" "zone" {
  name         = var.domain_name
  private_zone = false
}

# ── ACM Certificate ──────────────────────────────────────────────────────────
# AWS provider v6: region argument on the resource replaces the old alias provider.
# CloudFront requires certificates to be in us-east-1 regardless of where
# the rest of your infrastructure lives.

resource "aws_acm_certificate" "cert" {
  region                    = "us-east-1"
  domain_name               = var.domain_name
  subject_alternative_names = [var.www_domain_name]
  validation_method         = "DNS"
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cert" {
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── S3 Bucket (private — no public access) ──────────────────────────────────

resource "aws_s3_bucket" "site" {
  bucket = var.domain_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── CloudFront Origin Access Control (OAC) ──────────────────────────────────
# Modern replacement for deprecated OAI. Uses SigV4 signed requests.
# Verified args: origin_access_control_origin_type = "s3",
#   signing_behavior = "always", signing_protocol = "sigv4"

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.domain_name}-oac"
  description                       = "OAC for ${var.domain_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront Function: Hugo clean URL rewriting ────────────────────────────
# Hugo outputs /posts/hello/index.html; users request /posts/hello/
# Without this function S3 returns 403. runtime cloudfront-js-2.0 is valid.

resource "aws_cloudfront_function" "url_rewrite" {
  name    = "${replace(var.domain_name, ".", "-")}-url-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Append index.html to Hugo clean URLs"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri.endsWith('/')) {
        request.uri += 'index.html';
      } else if (!uri.includes('.')) {
        request.uri += '/index.html';
      }
      return request;
    }
  EOT
}

# ── CloudFront Distribution ──────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = var.domain_name
  aliases             = [var.domain_name, var.www_domain_name]
  price_class         = "PriceClass_100" # US, Canada, Europe
  tags                = var.tags

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-${var.domain_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${var.domain_name}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS Managed CachingOptimized policy — verified UUID from AWS docs.
    # min=1s, default=24h, max=365d. No cookies/headers/query strings.
    # IMPORTANT: Do NOT add forwarded_values — mutually exclusive with this.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.url_rewrite.arn
    }
  }

  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.cert]
}

# ── S3 Bucket Policy: allow only this CloudFront distribution ────────────────

data "aws_iam_policy_document" "s3_policy" {
  statement {
    sid     = "AllowCloudFrontOAC"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.s3_policy.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# ── Route 53 ALIAS records ───────────────────────────────────────────────────
# ALIAS required for zone apex — CNAMEs cannot be used at the apex.

resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.www_domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── GitHub Actions OIDC Provider ─────────────────────────────────────────────
# Using resource (not data source) — works on fresh AWS accounts.
# tls_certificate fetches thumbprint dynamically, surviving cert rotations.
# AWS (July 2023): thumbprint no longer used for validation but still
# required by Terraform. Dynamic fetch keeps the value accurate.

data "tls_certificate" "github_oidc" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# ── IAM Role for GitHub Actions ──────────────────────────────────────────────

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "opscode-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = var.tags
}

# Least-privilege: S3 sync + CloudFront invalidation only

data "aws_iam_policy_document" "deploy_perms" {
  statement {
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }
}

resource "aws_iam_role_policy" "deploy_perms" {
  name   = "opscode-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.deploy_perms.json
}
