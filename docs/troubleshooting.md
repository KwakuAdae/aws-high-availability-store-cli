# Troubleshooting

Load the saved IDs first: `source .lab-env`.

## The website returns 503 Service Unavailable

The load balancer has **no healthy targets**.

```bash
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output table
```

| Target state / reason | Meaning | Fix |
|-----------------------|---------|-----|
| (no targets) | The Auto Scaling group has not registered servers | Run Phase 6; check `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names kwaku-store-asg` |
| `initial` | Server is booting / installing NGINX | Wait 2-4 minutes |
| `unhealthy` · `Target.Timeout` | The load balancer cannot reach port 80 | The web SG must allow port 80 **from the ALB security group** |
| `unhealthy` · `Target.ResponseCodeMismatch` | NGINX answers, but not 200 | The user data failed to write `index.html`. Check the boot log (below) |
| `unhealthy` · `Target.FailedHealthChecks` | NGINX not running | Check the boot log (below) |

## Look inside a server without SSH

The servers have the Systems Manager role, so you can run commands on them:

```bash
ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names kwaku-store-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
CMD=$(aws ssm send-command --instance-ids "$ID" --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl status nginx --no-pager","tail -30 /var/log/cloud-init-output.log"]' \
  --query Command.CommandId --output text)
sleep 5
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$ID" --query StandardOutputContent --output text
```

Or open **EC2 → Instances → select → Connect → Session Manager** for a browser shell.

If `send-command` says the instance is not registered: wait 2-3 minutes after launch, and check the instance has the `kwaku-store-ec2-role` profile and a public IP (it needs internet access to reach Systems Manager).

## Auto Scaling problems

```bash
aws autoscaling describe-scaling-activities --auto-scaling-group-name kwaku-store-asg --max-items 5 \
  --query 'Activities[].{Time:StartTime, Status:StatusCode, Description:Description, Cause:Cause, Message:StatusMessage}' --output yaml
```

| Message | Fix |
|---------|-----|
| `Invalid IamInstanceProfile` | IAM was not ready yet when the template was used. Wait a minute; Auto Scaling retries. Or rerun Phase 3 |
| `We currently do not have sufficient t3.micro capacity` | Temporary. Auto Scaling retries in the other AZ |
| `You have requested more vCPU capacity than your current vCPU limit` | Service Quotas → EC2 → Running On-Demand Standard instances: request an increase |
| Servers replaced again and again | They fail health checks before NGINX starts. The grace period (300 s) should cover it; check the boot log |
| Desired capacity does not increase in the CPU test | Target tracking needs ~3 minutes of high CPU. Check `09-test-scaling.sh status`: is `AlarmHigh` in ALARM? |

## Load balancer and DNS

| Symptom | Fix |
|---------|-----|
| Browser: "can't reach this site" right after Phase 5 | DNS for a new load balancer takes a minute or two |
| Browser forces HTTPS | Type `http://` explicitly. This lab has no HTTPS listener |
| Only one server ever answers | Browsers keep connections open. Use `07-open-store.sh` (new request each time) or a private window |

## CLI errors

| Error | Fix |
|-------|-----|
| `An error occurred (InvalidGroup.Duplicate)` | Already created. Delete with `99-cleanup.sh` and start again, or reuse `.lab-env` |
| `DuplicateLoadBalancerName` / `DuplicateTargetGroupName` | Same: a previous run left it. `99-cleanup.sh` |
| `UnauthorizedOperation` / `AccessDenied` | Your IAM identity needs the permissions listed in the README prerequisites |
| `xxx is not set. Run the earlier steps first` | `.lab-env` is missing values: run the phases in order from the repo folder |

## Cleanup

| Symptom | Fix |
|---------|-----|
| `DependencyViolation` deleting a security group | Network interfaces from the load balancer or instances are still being released. The script retries; run it again after a minute |
| `DependencyViolation` deleting the VPC | Something is still inside. `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>` shows what |
| Something is still listed in the console | Run `./scripts/99-cleanup.sh` again: it is safe to repeat |
