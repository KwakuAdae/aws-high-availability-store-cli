#!/usr/bin/env bash
# Phase 6: the Auto Scaling group: keeps 2 healthy servers across both AZs (up to 4 under load),
# registers them with the target group, replaces any server the load balancer marks unhealthy,
# and scales on average CPU (target tracking, 60%).
source "$(dirname "$0")/config.sh"
require LT_ID SUBNET_A SUBNET_B TG_ARN

step "Auto Scaling group ${ASG_NAME}: min ${ASG_MIN}, desired ${ASG_DESIRED}, max ${ASG_MAX}"
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" \
  --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
  --vpc-zone-identifier "${SUBNET_A},${SUBNET_B}" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB --health-check-grace-period 300 \
  --min-size "$ASG_MIN" --desired-capacity "$ASG_DESIRED" --max-size "$ASG_MAX" \
  --default-instance-warmup 300 \
  --tags "Key=Project,Value=${PROJECT},PropagateAtLaunch=false"

step "Group metrics (GroupDesiredCapacity, GroupInServiceInstances...) for CloudWatch, every minute"
aws autoscaling enable-metrics-collection --auto-scaling-group-name "$ASG_NAME" --granularity 1Minute

step "Target tracking scaling policy: keep average CPU at ${CPU_TARGET}%"
aws autoscaling put-scaling-policy --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${PROJECT}-cpu-${CPU_TARGET}" --policy-type TargetTrackingScaling \
  --estimated-instance-warmup 300 \
  --target-tracking-configuration "{
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ASGAverageCPUUtilization\"},
    \"TargetValue\": ${CPU_TARGET}
  }" --query 'Alarms[].AlarmName' --output text | tr '\t' '\n' | grep -v '^None$' | sed 's/^/   alarm created: /' || true

step "Waiting for ${ASG_DESIRED} healthy servers in the target group (boot + NGINX install, ~3-5 minutes)"
for _ in $(seq 60); do
  N="$(healthy_count)"
  echo "   $(date +%H:%M:%S)  healthy targets: ${N}/${ASG_DESIRED}"
  [[ "$N" -ge "$ASG_DESIRED" ]] && break
  sleep 15
done

show_targets
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[].{Instance:InstanceId, AZ:AvailabilityZone, State:LifecycleState, Health:HealthStatus}' \
  --output table

echo ""
echo "✅ Servers are running. Next: ./scripts/07-open-store.sh"
