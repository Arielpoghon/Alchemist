# Terraform Usage

This directory creates the AWS infrastructure for the Alchemyst DevOps assignment.

## Files

- `provider.tf`: AWS provider and default tags
- `vpc.tf`: VPC, subnets, Internet Gateway, optional NAT gateway, route tables
- `security_groups.tf`: API and worker security groups
- `instances.tf`: EC2 key pair, API gateway, worker instances, Elastic IP
- `variables.tf`: inputs and validation
- `outputs.tf`: useful IPs, URLs, IDs, and SSH command
- `backend.tf.example`: optional S3 backend template
- `scripts/`: EC2 user-data scripts

## Commands

```bash
terraform init
terraform validate
terraform plan
terraform apply
terraform output
```

## Variables

Common overrides:

```bash
terraform apply \
  -var='worker_count=2' \
  -var='api_gateway_port=8000' \
  -var='enable_nat_gateway=true'
```

Disable NAT only when workers do not need internet during boot:

```bash
terraform apply -var='enable_nat_gateway=false'
```

## Outputs

```bash
terraform output -raw api_base_url
terraform output -raw api_gateway_public_ip
terraform output worker_private_ips
```

## Destroy

```bash
terraform destroy
```
