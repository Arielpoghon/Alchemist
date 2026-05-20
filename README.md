# Alchemyst DevOps Internship Assignment

Deploy the Alchemyst quickstart shape across multiple AWS VMs: a public JSON HTTP API gateway in a public subnet, and private worker VMs that receive RPC-style inference calls over the VPC.

## What This Includes

- Terraform IaC for AWS `us-east-1`
- VPC `10.0.0.0/16` with public and private subnets
- API gateway EC2 instance in the public subnet
- Configurable private worker EC2 instances
- Security groups that expose only the gateway publicly
- Bash user-data scripts with systemd services
- Express.js API gateway with `/health`, `/workers`, and `/infer`
- Architecture and production-hardening documentation

## Architecture

```text
Internet
  |
  | HTTP :8000
  v
Public subnet 10.0.1.0/24
  API gateway EC2 + Elastic IP
  |
  | HTTP RPC :9000-9010
  v
Private subnet 10.0.2.0/24
  worker-0 10.0.2.10:9000
  worker-1 10.0.2.11:9001
```

Workers do not receive public IP addresses. The API gateway also acts as a bastion for debugging worker instances.

## Prerequisites

- AWS account and AWS CLI credentials configured with `aws configure`
- Terraform `>= 1.5`
- SSH key at `~/.ssh/id_rsa.pub`

Generate an SSH key if needed:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

## Quick Start

```bash
cd terraform
terraform init
terraform validate
terraform plan
terraform apply
```

Get the API URL:

```bash
API_URL=$(terraform output -raw api_base_url)
echo "$API_URL"
```

## Test

```bash
curl "$API_URL/health"
curl "$API_URL/workers"
curl -X POST "$API_URL/infer" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What is 2+2?","model":"llama"}'
```

Example inference response:

```json
{
  "prompt": "What is 2+2?",
  "model": "llama",
  "result": "[python-worker-0] Received prompt for model \"llama\": What is 2+2?",
  "worker": {
    "name": "python-worker-0",
    "type": "python",
    "host": "10.0.2.10",
    "port": 9000
  },
  "duration_ms": 12,
  "timestamp": "2026-05-20T10:30:45.123Z"
}
```

Example health response:

```json
{
  "status": "ok",
  "timestamp": "2026-05-20T10:30:45.123Z",
  "uptime": 120.5,
  "workers": 2
}
```

Example worker response:

```json
{
  "workers": [
    {
      "name": "python-worker-0",
      "host": "10.0.2.10",
      "port": 9000,
      "type": "python",
      "status": "healthy"
    }
  ],
  "timestamp": "2026-05-20T10:30:45.123Z"
}
```

## Debugging

SSH to the API gateway:

```bash
terraform output -raw ssh_command
ssh -i ~/.ssh/id_rsa ec2-user@$(terraform output -raw api_gateway_public_ip)
```

Check services:

```bash
sudo systemctl status api-gateway
sudo journalctl -u api-gateway -f
```

From the API gateway, check worker connectivity:

```bash
curl http://10.0.2.10:9000/health
curl http://10.0.2.11:9001/health
```

Worker logs:

```bash
ssh ec2-user@10.0.2.10
sudo systemctl status alchemyst-worker
sudo journalctl -u alchemyst-worker -f
```

## Cost Note

The EC2 instances use `t2.micro` for the assignment/free-tier target. This scaffold enables a NAT gateway by default because private workers need outbound internet during first boot to download packages. NAT gateways are not free-tier resources.

| Resource | Assignment Setting | Free-Tier Note |
| --- | --- | --- |
| EC2 | `t2.micro` API and workers | Free-tier eligible, but total monthly hours are limited |
| EBS | Default root volumes | Free-tier eligible within account limits |
| Elastic IP | Attached to API gateway | No charge while attached and in use |
| NAT Gateway | Enabled by default | Not free-tier; roughly `$32/month` plus data processing if left running |

For the lowest possible short-lived demo cost, destroy the stack immediately after testing:

```bash
terraform destroy
```

If you build pre-baked AMIs or use VPC endpoints/package mirrors, you can disable NAT:

```bash
terraform apply -var='enable_nat_gateway=false'
```

## Cleanup

```bash
cd terraform
terraform destroy
```

## Repository Layout

```text
.
├── terraform/
│   ├── provider.tf
│   ├── vpc.tf
│   ├── security_groups.tf
│   ├── instances.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf.example
│   └── scripts/
│       ├── api-gateway-setup.sh
│       └── worker-setup.sh
├── src/
│   └── api-gateway.js
├── ARCHITECTURE.md
├── PRODUCTION_HARDENING.md
└── README.md
```

## Submission

Email:

- To: `anuran@getalchemystai.com`
- CC: `saumitra@getalchemystai.com`, `khushi@getalchemystai.com`
- Subject: `DevOps Internship Assignment - <Your Name>`

Include the GitHub repository link, deployment instructions, and any notes about cost or NAT configuration.
