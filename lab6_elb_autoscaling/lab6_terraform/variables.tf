variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (must be 2)"
  type        = list(string)
  default = [
    "10.0.1.0/24",
    "10.0.2.0/24",
  ]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (must be 2)"
  type        = list(string)
  default = [
    "10.0.11.0/24",
    "10.0.12.0/24",
  ]
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair to use for SSH access"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR from which SSH to instances is allowed"
  type        = string
  # Для боевого варианта лучше подставить сюда свой IP/32,
  # но для лаб можно временно оставить 0.0.0.0/0
  default = "0.0.0.0/0"
}

variable "instance_type" {
  description = "EC2 instance type for ASG instances"
  type        = string
  default     = "t3.micro"
}