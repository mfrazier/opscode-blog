---
title: "Building opscode.io"
date: 2026-03-04T00:00:00-08:00
draft: false
tags: ["hugo", "aws", "terraform", "github-actions", "cloudfront", "s3", "devops"]
description: "The infrastructure behind opscode.io - Hugo, S3, CloudFront, Route 53, and a GitHub Actions pipeline that deploys on every git push."
showToc: true
ShowCodeCopyButtons: true
---

First post, the stack. This is a static site deployed to AWS via a
fully automated pipeline. No servers, no databases, no CMS. Every post is a Markdown file
in a git repo.

## Stack Overview

- **Hugo** - static site generator
- **PaperMod** - theme
- **S3** - origin storage for built site files
- **CloudFront** - CDN, HTTPS, caching
- **ACM** - TLS certificate
- **Route 53** - DNS
- **GitHub Actions** - CI/CD
- **Terraform** - all infrastructure as code

## Hugo and PaperMod

[Hugo](https://gohugo.io) is a static site generator written in Go. Write Markdown, get
HTML. No runtime, no application server, nothing to patch or exploit.

The theme is [PaperMod](https://github.com/adityatelange/hugo-PaperMod) - clean, fast,
good syntax highlighting, dark mode. It lives in the repo as a git submodule so updates
are a single `git submodule update` rather than manually copying files.

## AWS Architecture

### S3

The built site sits in a private S3 bucket with all public access blocked. Nothing can
reach it directly - only CloudFront can, enforced by a bucket policy scoped to the
specific distribution ARN. This uses **Origin Access Control (OAC)** with SigV4 signed
requests, which is the current AWS recommended pattern.

### CloudFront

[CloudFront](https://aws.amazon.com/cloudfront/) handles everything the user actually
touches - HTTPS termination, caching, and global distribution. There are a few specifics
worth calling out:

**Caching** is split by content type. Static assets (CSS, JS, images) get a one-year
`Cache-Control` TTL. Hugo fingerprints these files so their URLs change when content
changes, making long cache lifetimes safe. HTML, XML, and JSON get five minutes since
they change with every post.

**URL rewriting** is handled by a CloudFront Function at the edge. Hugo generates clean
URLs like `/posts/how-this-blog-works/` but S3 expects the full path
`/posts/how-this-blog-works/index.html`. The function appends `index.html` before the
request hits the origin.

**Price class** is set to `PriceClass_100` covering the US, Canada, and Europe, which is
cheaper than serving from every edge location globally.

### ACM

[ACM](https://aws.amazon.com/certificate-manager/) provides the TLS certificate for
`opscode.io` and `www.opscode.io`. Free, auto-renews, fully managed by Terraform. One
quirk: CloudFront requires certificates to live in `us-east-1` regardless of where the
rest of your infrastructure is located. AWS provider v6 handles this with a `region` argument
directly on the resource, so no aliased provider block is needed.

DNS validation is used - Terraform creates the required CNAME records in Route 53 and ACM
validates and issues automatically.

### Route 53

Terraform adds two records to the existing hosted zone:

- `A` ALIAS record for `opscode.io` pointing to CloudFront
- `A` ALIAS record for `www.opscode.io` pointing to the same distribution

ALIAS records are an AWS-specific DNS extension that allow pointing a zone apex at another
AWS resource. Standard CNAMEs cannot be used at the zone apex - that is a DNS protocol
constraint, not an AWS one.

## Terraform

All infrastructure is defined in a `tf/` directory alongside the Hugo content in the same
repo:

```
tf/
├── .terraform-version    # pins 1.14.6 via tfenv
├── .tflint.hcl           # linter config
├── providers.tf          # terraform block, S3 backend, AWS provider
├── variables.tf          # domain, region, GitHub repo, tags
├── main.tf               # all resources
└── outputs.tf            # CloudFront ID, role ARN, bucket name
```

Remote state lives in a separate S3 bucket with versioning enabled and DynamoDB for state
locking. The AWS provider is pinned to `~> 6.0`. The headline change in v6 is per-resource
`region` support - previously you needed a second aliased `aws` provider just to create an
ACM certificate in `us-east-1`. Now it is a single argument on the resource.

## GitHub Actions

The pipeline in `.github/workflows/deploy.yml` triggers on every push to `main`:

```
checkout -> hugo build -> assume AWS role -> s3 sync -> cloudfront invalidation
```

**Authentication** uses OIDC. GitHub mints a short-lived JWT for each run, AWS exchanges
it for temporary credentials scoped to a dedicated IAM role. No access keys stored
anywhere, not in GitHub secrets, not in the repo.

The IAM role has exactly two permissions: S3 read/write on the site bucket and
`cloudfront:CreateInvalidation` on the distribution.

**S3 sync** runs in two passes, one for static assets with a one-year cache header,
one for HTML/XML/JSON with a five-minute cache header.

**CloudFront invalidation** with `--paths "/*"` runs after sync to clear edge caches
immediately. Total pipeline runtime is about 90 seconds.

## Cost

| Service | Monthly cost |
|---|---|
| S3 | ~$0.01 |
| CloudFront | ~$0.00 |
| ACM | &nbsp; $0.00 |
| Route 53 hosted zone | ~$0.50 |
| GitHub Actions | &nbsp; $0.00 |

Source, Terraform config, and workflow are all in the
[opscode-blog repo](https://github.com/mfrazier/opscode-blog).
