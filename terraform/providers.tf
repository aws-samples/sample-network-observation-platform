terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
    # AWS DevOps Agent (Tier 3) is only exposed via the AWS Cloud Control provider.
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.98.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

# Region and credentials come from the caller's AWS session/profile (no region baked in).
# Deploy into the account that will host the consolidated analysis plane
# (typically the Log Archive or a dedicated Security Tooling account).
provider "aws" {
  # Account-wide default tags applied to every resource this provider manages, on top of
  # each resource's own tags.
  default_tags {
    tags = {
      Platform = "network-observation-platform"
    }
  }
}

# AWS DevOps Agent is available only in a subset of Regions (N. Virginia, Oregon,
# Sydney, Tokyo, Frankfurt, Ireland). When the platform's own Region is not one of
# them, Tier 3's agent space is deployed here instead while still monitoring this
# account. Defaults to Europe (Ireland).
provider "aws" {
  alias  = "devops_agent"
  region = var.devops_agent_region
}

provider "awscc" {
  alias  = "devops_agent"
  region = var.devops_agent_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}
