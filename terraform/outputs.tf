output "api_gateway_public_ip" {
  description = "Elastic public IPv4 address for the API gateway."
  value       = aws_eip.api_gateway.public_ip
}

output "api_gateway_public_dns" {
  description = "Public DNS name for the API gateway instance."
  value       = aws_instance.api_gateway.public_dns
}

output "api_gateway_private_ip" {
  description = "Private IPv4 address for the API gateway."
  value       = aws_instance.api_gateway.private_ip
}

output "worker_private_ips" {
  description = "Private IPv4 addresses assigned to worker instances."
  value       = aws_instance.workers[*].private_ip
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = aws_subnet.private.id
}

output "api_gateway_sg_id" {
  description = "ID of the API gateway security group."
  value       = aws_security_group.api_sg.id
}

output "worker_sg_id" {
  description = "ID of the worker security group."
  value       = aws_security_group.worker_sg.id
}

output "ssh_command" {
  description = "SSH command for connecting to the API gateway bastion."
  value       = "ssh -i ~/.ssh/id_rsa ec2-user@${aws_eip.api_gateway.public_ip}"
}

output "api_base_url" {
  description = "Base URL for the public JSON HTTP API."
  value       = "http://${aws_eip.api_gateway.public_ip}:${var.api_gateway_port}"
}
