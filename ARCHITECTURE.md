# Architecture

## Overview

The deployment uses a small AWS VPC with one public API tier and one private worker tier. Terraform creates all networking, security groups, EC2 instances, an Elastic IP, and startup scripts.

## Network

- VPC: `10.0.0.0/16`
- Public subnet: `10.0.1.0/24`
- Private subnet: `10.0.2.0/24`
- Region: `us-east-1`
- Availability zone: `us-east-1a`

The public subnet routes `0.0.0.0/0` through an Internet Gateway. The private subnet routes outbound traffic through a NAT gateway by default so workers can install packages during boot.

## Components

### API Gateway

The API gateway is a `t2.micro` EC2 instance in the public subnet. It has an Elastic IP and runs an Express.js service on port `8000`.

Endpoints:

- `GET /health`: API process health
- `GET /workers`: worker health aggregation
- `POST /infer`: forwards prompt/model payloads to a selected worker

### Workers

Workers are `t2.micro` EC2 instances in the private subnet. Terraform assigns stable private IPs:

- `worker-0`: `10.0.2.10:9000`
- `worker-1`: `10.0.2.11:9001`
- Additional workers continue at `10.0.2.12:9002`, and so on

The worker service exposes:

- `GET /health`
- `POST /infer`

The setup scripts clone `https://github.com/Alchemyst-ai/quickstart` onto each instance for assignment context and run a stable wrapper service with predictable health and inference endpoints.

## Traffic Flow

```text
Client
  -> HTTP POST /infer on API gateway public IP:8000
  -> API gateway selects worker from generated workers.json
  -> API gateway sends HTTP RPC to worker private IP:9000+
  -> Worker returns JSON
  -> API gateway returns normalized JSON to client
```

## Security Model

### API Gateway Security Group

- Inbound SSH `22` from `0.0.0.0/0` for assignment debugging
- Inbound API port `8000` from `0.0.0.0/0`
- Inbound `80` and `443` reserved for future reverse proxy/TLS
- Outbound all traffic, needed for package installation and worker calls

### Worker Security Group

- SSH `22` only from the API gateway security group
- RPC `9000-9010` from the API gateway security group
- RPC `9000-9010` from the worker security group for inter-worker calls
- Outbound all traffic through the NAT gateway

Workers have no public IPs, so they are not directly reachable from the internet.

### Bastion Pattern

The API gateway doubles as a bastion host for the MVP:

```text
Developer laptop
  -> SSH to API gateway public IP
  -> SSH from API gateway to worker private IP
```

This keeps worker instances private while still allowing debugging during review.

## Terraform Design Decisions

- Stable worker private IPs avoid hard-coded guesses in the API config.
- `worker_count` is count-based and validated between `1` and `10`.
- `instance_type` is validated as `t2.micro` to match the assignment target.
- `backend.tf.example` is provided instead of a live backend so reviewers can run `terraform init` without pre-creating remote state resources.
- NAT is enabled by default for reliable first-boot package installation, but can be disabled with `enable_nat_gateway=false`.

## Trade-offs

- Single AZ keeps the assignment simple, but does not provide AZ-level failover.
- Direct EC2 gateway avoids ALB cost and complexity, but is not horizontally available.
- HTTP RPC is easy to inspect and debug, but gRPC or mTLS would be better for production worker communication.
- Systemd keeps the runtime lightweight for `t2.micro`; containers would improve portability in a production environment.

## Cost Analysis

| Resource | Current Choice | Cost Consideration |
| --- | --- | --- |
| API gateway | `t2.micro` | Free-tier eligible, subject to account monthly hour limits |
| Workers | `t2.micro`, count-based | More workers consume free-tier hours faster |
| EBS | Default root volumes | Free-tier eligible within account limits |
| Elastic IP | One attached IP | No charge while attached and in use |
| NAT Gateway | Enabled by default | Not free-tier; used so private workers can install packages at boot |

The lowest-cost demonstration path is to deploy, test, and destroy quickly. For longer-lived zero-cost demos, build AMIs with dependencies preinstalled and set `enable_nat_gateway=false`.

## Scaling Considerations

Horizontal scaling is controlled by `worker_count`. Increasing the variable creates additional private worker instances with stable private IPs and sequential RPC ports.

For production scale:

- Put API gateways behind an Application Load Balancer.
- Run API gateways and workers in Auto Scaling Groups.
- Spread public and private subnets across multiple availability zones.
- Use service discovery instead of static worker config.
- Move large-model inference to GPU-backed workers and a purpose-built serving runtime such as vLLM or Hugging Face TGI.

Vertical scaling is a matter of changing instance families, but the assignment validation intentionally pins `instance_type` to `t2.micro`. Remove that validation only after leaving the free-tier target.

## Disaster Recovery

The stack is stateless, so recovery is mostly infrastructure rebuild:

1. Keep Terraform code in Git.
2. Store production Terraform state in S3 with versioning and DynamoDB locking.
3. Rebuild with `terraform apply` if an instance or the whole VPC is lost.
4. For production, use immutable AMIs so recovery does not depend on public package repositories during an outage.
