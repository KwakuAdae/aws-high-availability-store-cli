#!/usr/bin/env bash
# Phase 11: save proof that everything works into evidence/ (text you can commit to GitHub,
# next to your screenshots). No credentials or secrets are written.
source "$(dirname "$0")/config.sh"
require VPC_ID ALB_ARN TG_ARN ALB_DNS
OUT="${ROOT_DIR}/evidence"
mkdir -p "$OUT"

run() {   # run FILE COMMAND...: save a command and its output
  local file="$OUT/$1"; shift
  { echo "\$ $*"; echo; "$@" 2>&1 || echo "(command failed: see the message above)"; } > "$file"
  echo "   wrote evidence/$(basename "$file")"
}

step "Collecting evidence ($(date -u '+%Y-%m-%d %H:%M UTC'))"
run 01-vpc-and-subnets.txt aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value, CIDR:CidrBlock, AZ:AvailabilityZone}' --output table
run 02-security-groups.txt aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[?GroupName!=`default`].{Group:GroupName, Inbound:IpPermissions}' --output json
run 03-launch-template.txt aws ec2 describe-launch-template-versions --launch-template-name "$LAUNCH_TEMPLATE" --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.{AMI:ImageId, Type:InstanceType, IMDS:MetadataOptions, Network:NetworkInterfaces}' --output json
run 04-load-balancer.txt aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName, DNS:DNSName, Scheme:Scheme, State:State.Code, AZs:AvailabilityZones[].ZoneName}' --output json
run 05-target-health.txt aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output table
run 06-auto-scaling-group.txt aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].{Min:MinSize, Desired:DesiredCapacity, Max:MaxSize, HealthCheck:HealthCheckType, Instances:Instances[].[InstanceId, AvailabilityZone, LifecycleState, HealthStatus]}' --output json
run 07-scaling-activity.txt aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" --max-items 10 \
  --query 'Activities[].{Time:StartTime, Status:StatusCode, Description:Description, Cause:Cause}' --output json
run 08-scaling-policy-and-alarms.txt aws cloudwatch describe-alarms \
  --query "MetricAlarms[?contains(AlarmName, '${PROJECT}')].{Alarm:AlarmName, State:StateValue, Metric:MetricName, Threshold:Threshold}" --output table

{
  echo "\$ 20 requests to http://${ALB_DNS}/server.json"; echo
  for _ in $(seq 20); do curl -s --max-time 10 "http://${ALB_DNS}/server.json"; echo; done
} > "$OUT/09-load-balancing.txt"
echo "   wrote evidence/09-load-balancing.txt"

echo ""
echo "✅ Evidence saved in evidence/. Add your screenshots to screenshots/ and commit both."
