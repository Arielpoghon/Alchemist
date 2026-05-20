# Production Hardening

This assignment scaffold is intentionally small. Before production use, the main improvements are security, observability, scaling, and repeatable image builds.

## Security

### Restrict SSH

The MVP opens SSH to `0.0.0.0/0` for review convenience. Production should either restrict SSH to trusted CIDRs or remove SSH entirely and use AWS Systems Manager Session Manager.

```hcl
cidr_blocks = ["203.0.113.10/32"]
```

Session Manager is better because it avoids public SSH access, reduces key handling, and provides an audit trail.

### Add HTTPS

Terminate TLS with an Application Load Balancer and AWS Certificate Manager:

- ACM certificate for `api.example.com`
- ALB HTTPS listener on `443`
- HTTP `80` redirect to HTTPS
- API instances registered in a target group

### Authenticate API Calls

Add one of:

- API key middleware for a simple assignment extension
- OAuth/JWT for user-level authorization
- AWS API Gateway in front of the service for managed auth and throttling

### Protect Worker RPC

Network isolation is enough for the MVP, but production worker traffic should use one or more of:

- mTLS between gateway and workers
- Signed internal requests
- Private service discovery with strict security groups
- VPC Flow Logs for auditability

### Secrets

Do not keep credentials in `.env` files. Use AWS Secrets Manager or SSM Parameter Store with an instance profile that grants least-privilege read access.

## Observability

### Logs

Ship systemd logs to CloudWatch Logs:

- `/aws/alchemyst/api-gateway`
- `/aws/alchemyst/workers`

Set retention, for example 30 days for dev and 90+ days for production.

### Metrics

Expose and alarm on:

- API request count
- Inference latency p50/p95/p99
- Worker error count
- Worker timeout count
- EC2 CPU and memory
- Disk utilization

Prometheus plus Grafana is a strong open-source option. CloudWatch is easier to integrate on AWS.

### Alerts

Create CloudWatch alarms for:

- API gateway unhealthy
- Worker unhealthy
- CPU above 80 percent
- High 5xx rate
- Inference latency above target

Route alerts to SNS, Slack, PagerDuty, or an incident-management tool.

## Scaling

### API Tier

Move from a single API gateway instance to:

- Launch Template
- Auto Scaling Group
- Application Load Balancer
- Multi-AZ public subnets

### Worker Tier

Move workers to an Auto Scaling Group in private subnets. Use health checks and target tracking policies based on queue depth, CPU, or GPU utilization.

### Larger Models

For 100x larger models, the current CPU instances are not suitable. Use GPU instances and specialized inference servers:

- vLLM
- Hugging Face Text Generation Inference
- NVIDIA Triton
- Ray Serve
- SageMaker endpoints if a managed service is acceptable

Techniques to control cost and latency:

- Quantization
- Continuous batching
- KV-cache optimization
- Model sharding across GPUs
- Response caching for repeated prompts
- Spot instances for burst capacity

## Reliability

Add:

- Multi-AZ subnets
- Auto Scaling health replacement
- Immutable AMIs built with Packer
- Blue/green or rolling deployments
- Load tests with k6
- Runbooks for common incidents

## High Availability

The MVP uses one availability zone and one API gateway instance. A production deployment should use:

- Two or more public subnets for an internet-facing ALB
- Two or more private subnets for workers
- API gateway Auto Scaling Group across availability zones
- Worker Auto Scaling Group across availability zones
- Health checks that remove bad instances automatically
- Rolling or blue/green deployments to avoid downtime during updates

## Terraform State

Use the provided `terraform/backend.tf.example` as a starting point. Production state should live in S3 with:

- Encryption enabled
- Versioning enabled
- DynamoDB locking
- Restricted IAM access

## Compliance

Recommended AWS controls:

- CloudTrail
- AWS Config
- VPC Flow Logs
- EBS encryption
- IAM least privilege
- Security Hub or equivalent posture management

## MVP To Production Checklist

- [ ] Restrict or remove SSH
- [ ] Add HTTPS
- [ ] Add API authentication
- [ ] Add CloudWatch logs and alarms
- [ ] Add ALB and Auto Scaling
- [ ] Use remote Terraform state
- [ ] Build immutable AMIs
- [ ] Add load testing
- [ ] Add incident runbooks
- [ ] Review cost model for NAT, EC2 hours, and GPU usage
