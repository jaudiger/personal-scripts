# Personal Scripts

## Instructions

This is my personal scripts I use to automate my daily tasks. Most of them are [Nushell](https://www.nushell.sh/) scripts, and a few ones are Bash scripts.

Here is a **non exhaustive** list of these scripts:

- Git repositories management:
  - [Git](./git-wrapper)
  - [GitLab](./gitlab-wrapper)
- Language wrappers:
  - [C](./c-wrapper)
  - [Go](./go-wrapper)
  - [Java](./java-wrapper)
  - [Javascript](./javascript-wrapper)
  - [Rust](./rust-wrapper)
  - [Zig](./zig-wrapper)
- Command wrappers:
  - [Docker](./docker-wrapper)
  - [Helm](./helm-wrapper)
  - [iamlive](./iamlive-wrapper)
  - [npm](./npm-wrapper)
  - [Terraform](./terraform-wrapper)
  - [Terragrunt](./terragrunt-wrapper)

## CI / CD

The CI/CD pipeline is configured using GitHub Actions. The workflow is defined in the [`.github/workflows`](.github/workflows) folder:

- Static Analysis (Bash scripts, GitHub Actions)

Additionally, Dependabot is configured to automatically update dependencies (GitHub Actions).

## Repository configuration

The settings of this repository are managed from the [gitops-deployments](https://github.com/jaudiger/gitops-deployments) repository using Terraform. The actual configuration applied is located in the Terraform module [`modules/github-repository`](https://github.com/jaudiger/gitops-deployments/tree/main/modules/github-repository).
