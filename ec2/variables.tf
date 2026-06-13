variable "key_name" {
  description = "Name of the EC2 key pair"
  type        = string
  default     = "datapipeline_keypair"
}

variable "vpc_id" {
  description = "ID of the VPC to launch into"
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet to launch instances into"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC, used for in-VPC ingress rules"
  type        = string
}
