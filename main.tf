terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "eu-west-2" }

variable "key_name" { default = "my-keypair" }
variable "vpc_id"   { default = "" } # use default VPC if empty

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter { name = "vpc-id"; values = [data.aws_vpc.default.id] }
}

resource "aws_security_group" "main_sg" {
  name   = "mysql-airbyte-minio-sg"
  vpc_id = data.aws_vpc.default.id

  ingress { from_port = 22,    to_port = 22,    protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 3306,  to_port = 3306,  protocol = "tcp", cidr_blocks = ["10.0.0.0/8"] }
  ingress { from_port = 8000,  to_port = 8000,  protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] } # Airbyte UI
  ingress { from_port = 9000,  to_port = 9001,  protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] } # MinIO

  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }
}

# ---------------- MySQL EC2 ----------------
resource "aws_instance" "mysql" {
  ami                    = "ami-0c1c30571d2dae5c9" # Ubuntu 22.04 eu-west-2
  instance_type          = "t3.medium"
  key_name               = var.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.main_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y mysql-server
    sed -i 's/127.0.0.1/0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
    systemctl restart mysql
    mysql -e "CREATE DATABASE IF NOT EXISTS sourcedb;"
    mysql -e "CREATE USER 'airbyte'@'%' IDENTIFIED WITH mysql_native_password BY 'AirbytePass123!';"
    mysql -e "GRANT ALL PRIVILEGES ON sourcedb.* TO 'airbyte'@'%';"
    mysql -e "FLUSH PRIVILEGES;"
    # sample table
    mysql sourcedb -e "CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(100), email VARCHAR(100));"
    mysql sourcedb -e "INSERT INTO customers VALUES (1,'Alice','alice@example.com'),(2,'Bob','bob@example.com');"
  EOF

  tags = { Name = "mysql-source" }
}

# ---------------- Airbyte + MinIO EC2 ----------------
resource "aws_instance" "airbyte_minio" {
  ami                    = "ami-0c1c30571d2dae5c9"
  instance_type          = "t3.large"
  key_name               = var.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.main_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io docker-compose-plugin curl unzip jq
    systemctl enable docker && systemctl start docker

    # ---- MinIO ----
    mkdir -p /opt/minio/data
    docker run -d --name minio \
      -p 9000:9000 -p 9001:9001 \
      -v /opt/minio/data:/data \
      -e "MINIO_ROOT_USER=minioadmin" \
      -e "MINIO_ROOT_PASSWORD=minioadmin123" \
      minio/minio server /data --console-address ":9001"

    sleep 10
    # create bucket
    docker run --rm --network host --entrypoint sh minio/mc -c "
      mc alias set local http://localhost:9000 minioadmin minioadmin123 &&
      mc mb local/mysql-ingest
    "

    # ---- Airbyte (via abctl) ----
    curl -LsfS https://get.airbyte.com | bash -s -- --no-browser
  EOF

  tags = { Name = "airbyte-minio" }
}

output "mysql_public_ip"  { value = aws_instance.mysql.public_ip }
output "airbyte_minio_ip" { value = aws_instance.airbyte_minio.public_ip }
output "minio_console_url" { value = "http://${aws_instance.airbyte_minio.public_ip}:9001" }
output "airbyte_ui_url"    { value = "http://${aws_instance.airbyte_minio.public_ip}:8000" }