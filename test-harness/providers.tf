terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

# Region and credentials come from the caller's session/profile.
# Deploy into a single, disposable TEST account — this harness creates chargeable
# resources (AWS Network Firewall endpoint, Transit Gateway). See the README.
provider "aws" {
  default_tags {
    tags = {
      Platform  = "network-observation-platform"
      Lifecycle = "disposable-test"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
