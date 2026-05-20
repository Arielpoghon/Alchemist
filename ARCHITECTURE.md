# Architecture

## Overview

The deployment uses a small AWS VPC with one public API tier and one private worker tier. Terraform creates all networking, security groups, EC2 instances, an Elastic IP, and startup scripts. The runtime uses the official Alchemyst May 2026 `quickstart` workers and the iii engine.

## Network

- VPC: `10.0.0.0/16`
- Public subnet: `10.0.1.0/24`
- Private subnet: `10.0.2.0/24`
- Region: `us-east-1`
- Availability zone: `us-east-1a`

The public subnet routes `0.0.0.0/0` through an Internet Gateway. The private subnet routes outbound traffic through a NAT gateway by default so workers can install packages during boot.

## Components

### API Gateway

The API gateway is an EC2 instance in the public subnet. It has an Elastic IP, runs an Express.js service on port `8000`, and runs the iii engine with the HTTP trigger bound locally on `127.0.0.1:3111`.

Endpoints:

- `GET /health`: API process health
- `GET /workers`: worker health aggregation
- `POST /infer`: forwards prompt/model payloads to a selected worker

### Workers

Workers are EC2 instances in the private subnet. Terraform assigns stable private IPs:

- `worker-0`: `10.0.2.10`, official Python `inference-worker`
- `worker-1`: `10.0.2.11`, official TypeScript `caller-worker`
- Additional workers alternate Python and TypeScript roles

Workers connect back to the iii engine on the API gateway over `ws://<api-gateway-private-ip>:49134`. The TypeScript worker registers `http::run_inference_over_http`, which forwards to `inference::get_response`; that function triggers the Python worker function `inference::run_inference`.

The setup scripts clone `https://github.com/Alchemyst-ai/hiring` and run the bundled `may-2026/devops/quickstart` worker code.

## Traffic Flow

```text
Client
  -> HTTP POST /infer on API gateway public IP:8000
  -> API gateway normalizes prompt into chat messages
  -> API gateway calls local iii HTTP trigger /v1/chat/completions
  -> TypeScript caller-worker receives trigger through iii
  -> caller-worker triggers Python inference-worker through iii RPC
  -> Python inference-worker returns model output
  -> API gateway returns normalized JSON to client
```

## Security Model

### API Gateway Security Group

- Inbound SSH `22` from `0.0.0.0/0` for assignment debugging
- Inbound API port `8000` from `0.0.0.0/0`
- Inbound `80` and `443` reserved for future reverse proxy/TLS
- Inbound iii engine WebSocket `49134` from the worker security group
- Outbound all traffic, needed for package installation and worker calls

### Worker Security Group

- SSH `22` only from the API gateway security group
- RPC `9000-9010` from the API gateway security group, reserved for alternate direct worker RPC demos
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
| API gateway | `t3.large` by default | Larger than needed for the gateway, but keeps one variable simple |
| Workers | `t3.large`, count-based | Safer for the official Python model worker; short demos should fit AWS credits |
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

Vertical scaling is a matter of changing instance families. The Terraform variable allows `t2.micro`, `t3.small`, `t3.medium`, and `t3.large`; `t3.large` is the safer default for the official Python inference worker.

## Disaster Recovery

The stack is stateless, so recovery is mostly infrastructure rebuild:

1. Keep Terraform code in Git.
2. Store production Terraform state in S3 with versioning and DynamoDB locking.
3. Rebuild with `terraform apply` if an instance or the whole VPC is lost.
4. For production, use immutable AMIs so recovery does not depend on public package repositories during an outage.
