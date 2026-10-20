#!/usr/bin/env bash
# Phase 4: the target group: the list of servers that receive traffic, plus their health check.
source "$(dirname "$0")/config.sh"
require VPC_ID

step "Target group ${TARGET_GROUP} (HTTP 80, health check GET /)"
save TG_ARN "$(aws elbv2 create-target-group --name "$TARGET_GROUP" \
  --protocol HTTP --port 80 --protocol-version HTTP1 --ip-address-type ipv4 \
  --vpc-id "$VPC_ID" --target-type instance \
  --health-check-protocol HTTP --health-check-path / \
  --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"

# Finish in-flight requests for 30 s (instead of 300) when a server is removed
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 --output text >/dev/null

echo ""
echo "   Health check: every 15 s; 2 failures = unhealthy, 2 successes = healthy."
echo "   No servers registered yet: the Auto Scaling group will register them (step 6)."
echo "✅ Target group ready. Next: ./scripts/05-create-load-balancer.sh"
