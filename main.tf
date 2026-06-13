terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "eu-west-2"
}

module "vpc" {
  source = "./Vpc"
}

module "ec2" {
  source    = "./ec2"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnet_id
  vpc_cidr  = module.vpc.vpc_cidr
}

output "mysql_public_ip" { value = module.ec2.mysql_public_ip }
output "airbyte_minio_ip" { value = module.ec2.airbyte_minio_ip }
output "minio_console_url" { value = module.ec2.minio_console_url }
output "airbyte_ui_url" { value = module.ec2.airbyte_ui_url }
