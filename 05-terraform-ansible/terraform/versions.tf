terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # STATE: local, deliberately, for this exercise.
  #
  # A local terraform.tfstate is fine for a single operator applying and
  # destroying inside one session, and it keeps the exercise reproducible from
  # a clone with no prior setup.
  #
  # For anything shared it would be wrong, for two reasons that matter:
  #
  #   1. State contains secrets in plaintext. Generated passwords, private
  #      keys and any sensitive output land in the state file unencrypted.
  #      That is why .tfstate is gitignored here and why scripts/audit.sh
  #      fails the build if one is ever tracked.
  #   2. Concurrent applies corrupt it. Two operators running apply against
  #      the same local state produce a lost update - one writes over the
  #      other's resource records and Terraform then believes resources exist
  #      that do not, or vice versa.
  #
  # The shared answer is a GCS backend, which gives both remote storage and
  # object-level locking:
  #
  #   backend "gcs" {
  #     bucket = "tfstate-<project>-<env>"
  #     prefix = "05-terraform-ansible"
  #   }
  #
  # GCS backend locking is automatic and needs no separate lock table - unlike
  # S3, which historically required a DynamoDB table for the same guarantee.
  # The bucket should have versioning on, so a corrupted state can be rolled
  # back, and uniform bucket-level access so the ACL surface is small.
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
