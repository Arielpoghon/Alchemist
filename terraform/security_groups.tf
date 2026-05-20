resource "aws_security_group" "api_sg" {
  name        = "alchemyst-api-gateway-sg"
  description = "Public API gateway access and private worker egress"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH for assignment debugging; restrict this in production."
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Assignment JSON HTTP API"
    from_port   = var.api_gateway_port
    to_port     = var.api_gateway_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP for future reverse proxy use"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS for future TLS termination"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Reach workers and download setup dependencies"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alchemyst-api-gateway-sg"
  }
}

resource "aws_security_group" "worker_sg" {
  name        = "alchemyst-worker-sg"
  description = "Private worker RPC access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH only through API gateway bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.api_sg.id]
  }

  ingress {
    description     = "RPC from API gateway"
    from_port       = 9000
    to_port         = 9010
    protocol        = "tcp"
    security_groups = [aws_security_group.api_sg.id]
  }

  ingress {
    description = "Inter-worker RPC"
    from_port   = 9000
    to_port     = 9010
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Package downloads through NAT, plus outbound RPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alchemyst-worker-sg"
  }
}
