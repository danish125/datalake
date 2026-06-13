# Always resolve the latest Ubuntu 22.04 LTS AMI for the current region,
# so the config isn't tied to a hardcoded ID that gets deregistered.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "main_sg" {
  name   = "mysql-airbyte-minio-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 9000
    to_port     = 9001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------- MySQL EC2 ----------------
resource "aws_instance" "mysql" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.main_sg.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

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
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.xlarge" # 4 vCPU / 16 GB — Airbyte (kind) needs the headroom
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.main_sg.id]

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # ---- Docker (from Docker's official apt repo) ----
    # Ubuntu's default repos do NOT carry docker-compose-plugin, and a single
    # missing package aborts the whole apt-get install, so install Docker
    # properly from Docker's repo.
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg unzip jq
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

output "mysql_public_ip" { value = aws_instance.mysql.public_ip }
output "airbyte_minio_ip" { value = aws_instance.airbyte_minio.public_ip }
output "minio_console_url" { value = "http://${aws_instance.airbyte_minio.public_ip}:9001" }
output "airbyte_ui_url" { value = "http://${aws_instance.airbyte_minio.public_ip}:8000" }