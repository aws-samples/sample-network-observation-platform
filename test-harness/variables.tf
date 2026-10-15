variable "name_prefix" {
  description = "Prefix for all test-harness resource names."
  type        = string
  default     = "netobs-test"
}

variable "vpc_cidr" {
  description = "CIDR for the test inspection VPC (see cidr-conventions: /24 for an inspection VPC)."
  type        = string
  default     = "10.0.0.0/24"
}

variable "az_count" {
  description = "Number of Availability Zones to spread the firewall and TGW subnets across."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project   = "network-observation-platform"
    Component = "test-harness"
    ManagedBy = "terraform"
    Lifecycle = "disposable-test"
  }
}
