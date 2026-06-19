# DSO Automation for Modernisation Platform

## Introduction 🗣

This repository contains GitHub Actions workflows and supporting shell scripts for automating operations across DSO-managed environments on the [Ministry of Justice Modernisation Platform](https://github.com/ministryofjustice/modernisation-platform).

## Managed Applications

- `nomis`
- `oasys`
- `delius-core`
- `delius-mis`
- `nomis-combined-reporting`
- `corporate-staff-rostering`
- `hmpps-oem`
- `oasys-national-reporting`

## Architecture

**Workflows** in this repository orchestrate automation tasks (environment start/stop, AMI cleanup, database refreshes, certificate renewals, etc.) and depend on [`ministryofjustice/modernisation-platform-configuration-management`](https://github.com/ministryofjustice/modernisation-platform-configuration-management) for Ansible playbooks, inventory, and configuration.

**Composite actions** in `.github/actions/` provide reusable building blocks:
- `get_account_details` — resolves an AWS account ID from GitHub secrets (with fallback to AWS Secrets Manager) and generates an IAM role ARN for OIDC authentication.
- `setup_oracle_target_access` — resolves Ansible target names, batches host/database pairs, and configures AWS credentials for Oracle-specific workflows.

**Shell scripts** in `src/` are called directly from workflow steps and support a `dryrun` flag (`-d`) for safe testing of destructive operations.

## AWS Access

All jobs authenticate to AWS via OIDC, assuming the `modernisation-platform-oidc-cicd` IAM role. Account IDs are resolved from the `MODERNISATION_PLATFORM_ENVIRONMENT_MANAGEMENT` secret, with automatic fallback to AWS Secrets Manager for accounts not yet present in the secret.
