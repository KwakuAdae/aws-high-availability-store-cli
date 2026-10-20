#!/usr/bin/env bash
# Phase 5: the internet-facing Application Load Balancer in both public subnets,
# with an HTTP :80 listener that forwards to the target group (~3 minutes).
source "$(dirname "$0")/config.sh"
require SUBNET_A SUBNET_B ALB_SG_ID TG_ARN

step "Application Load Balancer ${ALB_NAME}"
save ALB_ARN "$(aws elbv2 create-load-balancer --name "$ALB_NAME" \
  --type application --scheme internet-facing --ip-address-type ipv4 \
  --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$ALB_SG_ID" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
save ALB_DNS "$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)"

step "Listener HTTP :80 → forward to ${TARGET_GROUP}"
save LISTENER_ARN "$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
  --query 'Listeners[0].ListenerArn' --output text)"

step "Waiting for the load balancer to become active"
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName, State:State.Code, Scheme:Scheme, AZs:join(`, `, AvailabilityZones[].ZoneName)}' \
  --output table

echo ""
echo "   The load balancer exists, but the site will return 503 until servers are attached (step 6)."
echo "✅ Load balancer ready. Next: ./scripts/06-create-auto-scaling-group.sh"
