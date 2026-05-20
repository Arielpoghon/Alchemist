data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  worker_private_ips = [
    for index in range(var.worker_count) : cidrhost(var.private_subnet_cidr, 10 + index)
  ]

  workers = [
    for index, ip in local.worker_private_ips : {
      name = index % 2 == 0 ? "python-worker-${index}" : "ts-worker-${index}"
      host = ip
      port = 9000 + index
      type = index % 2 == 0 ? "python" : "typescript"
    }
  ]
}

resource "aws_key_pair" "deployer" {
  key_name   = var.ssh_key_name
  public_key = file(pathexpand(var.ssh_public_key_path))

  tags = {
    Name = var.ssh_key_name
  }
}

resource "aws_instance" "api_gateway" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.api_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.deployer.key_name

  user_data_base64 = base64encode(templatefile("${path.module}/scripts/api-gateway-setup.sh", {
    api_gateway_port = var.api_gateway_port
    workers_json     = jsonencode({ workers = local.workers })
  }))

  user_data_replace_on_change = true

  depends_on = [aws_route_table_association.public]

  tags = {
    Name = "api-gateway"
    Role = "api"
  }
}

resource "aws_eip" "api_gateway" {
  domain   = "vpc"
  instance = aws_instance.api_gateway.id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "api-gateway-eip"
  }
}

resource "aws_instance" "workers" {
  count                       = var.worker_count
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  private_ip                  = local.worker_private_ips[count.index]
  vpc_security_group_ids      = [aws_security_group.worker_sg.id]
  associate_public_ip_address = false
  key_name                    = aws_key_pair.deployer.key_name

  user_data_base64 = base64encode(templatefile("${path.module}/scripts/worker-setup.sh", {
    worker_index   = count.index
    worker_port    = 9000 + count.index
    api_gateway_ip = aws_instance.api_gateway.private_ip
  }))

  user_data_replace_on_change = true

  depends_on = [aws_route_table_association.private]

  tags = {
    Name = "worker-${count.index}"
    Role = "worker"
  }
}
