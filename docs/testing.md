# Test plan and results

Fill in the **Result** column when you run the lab, and keep the matching file from `evidence/` or a screenshot from `screenshots/` as proof.

| # | Test | How | Expected | Result |
|---|------|-----|----------|--------|
| 1 | Network | `01-create-vpc.sh` output, VPC console | 2 public subnets in different AZs; `0.0.0.0/0 → igw` | |
| 2 | Servers not directly reachable | `curl -m 5 http://<server-public-ip>/` | Times out (web SG allows the ALB only) | |
| 3 | No SSH | `aws ec2 describe-security-groups` | No port 22 rule in either group | |
| 4 | Two healthy servers | `aws elbv2 describe-target-health` | 2 × `healthy`, in two different AZs | |
| 5 | Website works | Open `http://<alb-dns>` | Kwaku Online Store page | |
| 6 | Load balancing | `07-open-store.sh 20` | Responses from both instances | |
| 7 | Server failure | `08-test-failover.sh` | Website checks keep succeeding (at most a few failures) | |
| 8 | Automatic recovery | `08-test-failover.sh`, ASG Activity | New instance launched, 2 healthy within ~5 minutes | |
| 9 | Manual capacity | `09-test-scaling.sh manual` | 3rd server becomes healthy, then removed | |
| 10 | Automatic scaling | `09-test-scaling.sh cpu 12` | `AlarmHigh` → desired capacity rises above 2 | |
| 11 | Scale in | wait ~15 min after test 10 | Desired capacity back to 2 | |
| 12 | Monitoring | CloudWatch dashboard | All 6 widgets show data | |
| 13 | Alerting | Run test 7 with `ALERT_EMAIL` set | `kwaku-store-unhealthy-hosts` goes to ALARM, email received, then OK | |
| 14 | Cleanup | `99-cleanup.sh` | No instances, load balancers, VPC or Elastic IPs left | |

## Test 2: prove the servers are protected

```bash
source .lab-env
IP=$(aws ec2 describe-instances --instance-ids $(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names kwaku-store-asg --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text) \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
curl -m 5 "http://${IP}/" || echo "blocked: only the load balancer can reach the servers ✔"
```

## Measuring downtime precisely during test 7

`08-test-failover.sh` prints `website ok=N failed=M`. Each check is 2 seconds apart, so the maximum interruption is roughly `failed × 2` seconds. With ELB health checks every 15 s and an unhealthy threshold of 2, the load balancer stops sending traffic to a dead server within about 30 seconds. A terminated instance is deregistered faster than that, because Auto Scaling removes it from the target group as it shuts down.
