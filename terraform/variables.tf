variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public API subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private worker subnet."
  type        = string
  default     = "10.0.2.0/24"
}

variable "availability_zone" {
  description = "Single availability zone used for this MVP."
  type        = string
  default     = "us-east-1a"
}

variable "worker_count" {
  description = "Number of private worker VMs."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "worker_count must be between 1 and 10."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.large is safer for the official quickstart Python model worker; use smaller only after testing memory."
  type        = string
  default     = "t3.large"

  validation {
    condition     = contains(["t2.micro", "t3.small", "t3.medium", "t3.large"], var.instance_type)
    error_message = "instance_type must be one of: t2.micro, t3.small, t3.medium, t3.large."
  }
}

variable "api_gateway_port" {
  description = "Public API gateway HTTP port."
  type        = number
  default     = 8000

  validation {
    condition     = var.api_gateway_port >= 1024 && var.api_gateway_port <= 65535
    error_message = "api_gateway_port must be between 1024 and 65535."
  }
}

variable "ssh_key_name" {
  description = "EC2 SSH key pair name."
  type        = string
  default     = "alchemyst-deployer-key"
}

variable "ssh_public_key_path" {
  description = "Local SSH public key path used to create the AWS key pair."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "dev"
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so private workers can download packages during boot. Disable only if using prebuilt AMIs or VPC endpoints."
  type        = bool
  default     = true
}
