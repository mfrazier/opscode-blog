<!-- Template kindly borrowed from https://github.com/othneildrew/Best-README-Template -->
<a id="readme-top"></a>

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![MIT License][license-shield]][license-url]
[![LinkedIn][linkedin-shield]][linkedin-url]

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#configuration">Configuration</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
  </ol>
</details>

<br />
<div align="center">
  <h3 align="center">opscode-blog</h3>

  <p align="center">
    Terraform and Hugo configuration for <a href="https://opscode.io">opscode.io</a>
    <br />
    <br />
    <a href="https://github.com/mfrazier/opscode-blog/issues/new?labels=bug">Report Bug</a>
    &nbsp;·&nbsp;
    <a href="https://github.com/mfrazier/opscode-blog/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

---

<!-- ABOUT THE PROJECT -->
<a id="about-the-project"></a>
## About The Project

This repository contains the Terraform infrastructure and Hugo site content for
[opscode.io](https://opscode.io) - a personal tech blog covering DevOps, Linux systems
administration, automation, and home lab projects.

- All AWS infrastructure (S3, CloudFront, ACM, Route 53, IAM) is managed by Terraform in `tf/`
- Hugo site content and configuration live in `hugo/`
- Deployment is fully automated via GitHub Actions on every push to `main`

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Built With

* [![Terraform][Terraform]][Terraform-url]
* [![tfenv][Tfenv]][Tfenv-url]
* [![Hugo][Hugo]][Hugo-url]
* [![AWS][AWS]][AWS-url]
* [![GitHub Actions][GHActions]][GHActions-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

<!-- GETTING STARTED -->
<a id="getting-started"></a>
## Getting Started

Development is done on macOS. Hugo is required to build the static site and Terraform is
managed via tfenv, which handles version pinning similarly to rbenv or pyenv.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Prerequisites

**macOS (Apple Silicon)**

Install all required tools via [Homebrew](https://brew.sh). If Homebrew is not installed:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After install, add Homebrew to your shell profile as instructed by the installer, then:

```sh
brew install hugo tfenv tflint awscli git
```

Install and pin Terraform via tfenv:

```sh
tfenv install 1.14.6
tfenv use 1.14.6
```

Verify everything is working:

```sh
hugo version      # should show extended and darwin/arm64
terraform version # Terraform v1.14.6 on darwin_arm64
tflint --version
aws --version
```

Clone the repo with submodules to pull in the PaperMod theme:

```sh
git clone --recurse-submodules https://github.com/mfrazier/opscode-blog.git
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Configuration

**Hugo**

- Site configuration is in `hugo/hugo.toml`
- Posts live in `hugo/content/posts/` as Markdown files
- PaperMod is included as a git submodule — do not copy theme files directly

**Terraform**

- Variables are defined in `tf/variables.tf` — update `github_repo` to match your fork
- Remote state is stored in S3 with DynamoDB locking — the state bucket must be
  bootstrapped once before running `terraform init`
- `tf/.terraform-version` is read automatically by tfenv

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

<!-- USAGE -->
<a id="usage"></a>
## Usage

**Local development**

```sh
hugo server --source hugo/
# visit http://localhost:1313
```

**New post**

```sh
cd hugo
hugo new posts/my-post-title.md
# edit the file, set draft: false in front matter when ready to publish
```

Push to `main` to deploy. GitHub Actions runs the following pipeline automatically:

```
checkout -> hugo build -> assume AWS role via OIDC -> s3 sync -> cloudfront invalidation
```

Authentication uses OIDC — no AWS credentials are stored in the repo or GitHub secrets.
GitHub mints a short-lived JWT per run and AWS exchanges it for temporary credentials
scoped to a least-privilege IAM role.

**Terraform**

```sh
cd tf
tflint --init && tflint
terraform init
terraform plan
terraform apply
```

Required GitHub Actions secrets:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | `terraform output github_actions_role_arn` |
| `AWS_REGION` | `us-west-2` |
| `S3_BUCKET` | `opscode.io` |
| `CLOUDFRONT_DISTRIBUTION_ID` | `terraform output cloudfront_distribution_id` |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## License

Distributed under the MIT License. See `LICENSE` for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->
[contributors-shield]: https://img.shields.io/github/contributors/mfrazier/opscode-blog.svg?style=for-the-badge
[contributors-url]: https://github.com/mfrazier/opscode-blog/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/mfrazier/opscode-blog.svg?style=for-the-badge
[forks-url]: https://github.com/mfrazier/opscode-blog/network/members
[stars-shield]: https://img.shields.io/github/stars/mfrazier/opscode-blog.svg?style=for-the-badge
[stars-url]: https://github.com/mfrazier/opscode-blog/stargazers
[issues-shield]: https://img.shields.io/github/issues/mfrazier/opscode-blog.svg?style=for-the-badge
[issues-url]: https://github.com/mfrazier/opscode-blog/issues
[license-shield]: https://img.shields.io/github/license/mfrazier/opscode-blog.svg?style=for-the-badge
[license-url]: https://github.com/mfrazier/opscode-blog/blob/main/LICENSE
[linkedin-shield]: https://img.shields.io/badge/-LinkedIn-black.svg?style=for-the-badge&logo=linkedin&colorB=555
[linkedin-url]: https://www.linkedin.com/in/malcolm-frazier-7378a574/

[Terraform]: https://img.shields.io/badge/terraform-7b42bc?style=for-the-badge&logo=terraform&logoColor=white
[Terraform-url]: https://terraform.io/
[Tfenv]: https://img.shields.io/badge/tfenv-000000?style=for-the-badge&logo=github&logoColor=white
[Tfenv-url]: https://github.com/tfutils/tfenv
[Hugo]: https://img.shields.io/badge/hugo-00875d?style=for-the-badge&logo=hugo&logoColor=white
[Hugo-url]: https://gohugo.io/
[AWS]: https://img.shields.io/badge/AWS-232f3e?style=for-the-badge&logo=amazonwebservices&logoColor=white
[AWS-url]: https://aws.amazon.com/
[GHActions]: https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white
[GHActions-url]: https://github.com/features/actions
