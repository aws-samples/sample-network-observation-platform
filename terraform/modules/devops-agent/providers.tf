terraform {
  required_providers {
    # AWS DevOps Agent resources are only available via the AWS Cloud Control (awscc)
    # provider, and only in the 6 supported Regions. The root module passes region-
    # pinned aws/awscc providers (see the module block's `providers` argument).
    aws = {
      source = "hashicorp/aws"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.98.0"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
