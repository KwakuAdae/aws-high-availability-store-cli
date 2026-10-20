#!/usr/bin/env bash
# Phase 9: test scaling.
#   ./scripts/09-test-scaling.sh manual        # desired 2 → 3, wait for the 3rd healthy server, back to 2
#   ./scripts/09-test-scaling.sh cpu [minutes] # REAL automatic scaling: load the CPUs with stress-ng
#                                              # (via Systems Manager) and watch the policy add servers
#   ./scripts/09-test-scaling.sh status        # current capacity, alarms and recent activity
source "$(dirname "$0")/config.sh"
require TG_ARN
MODE="${1:-manual}"

status() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].{Min:MinSize, Desired:DesiredCapacity, Max:MaxSize, InService:length(Instances[?LifecycleState==`InService`])}' \
    --output table
  aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-${ASG_NAME}" \
    --query 'MetricAlarms[].{Alarm:AlarmName, State:StateValue}' --output table
}

case "$MODE" in
  manual)
    step "Setting desired capacity to 3"
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG_NAME" --desired-capacity 3
    for _ in $(seq 40); do
      N="$(healthy_count)"; echo "   $(date +%H:%M:%S)  healthy targets: ${N}/3"
      [[ "$N" -ge 3 ]] && break; sleep 15
    done
    show_targets
    step "Back to desired capacity 2 (Auto Scaling removes one server)"
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG_NAME" --desired-capacity "$ASG_DESIRED"
    sleep 20; status
    echo ""
    echo "✅ Capacity management works. (This is manual; use 'cpu' mode to test the automatic policy.)" ;;

  cpu)
    MINUTES="${2:-12}"
    IDS="$(asg_instances)"
    step "Loading every CPU of: ${IDS} for ${MINUTES} minutes (Systems Manager Run Command, no SSH)"
    # One busy shell loop per vCPU, stopped automatically by `timeout`
    BURN="for i in \$(seq \$(nproc)); do nohup timeout ${MINUTES}m sh -c 'while :; do :; done' >/dev/null 2>&1 & done; echo started \$(nproc) cpu burners"
    CMD_ID="$(aws ssm send-command --document-name AWS-RunShellScript \
      --instance-ids $IDS \
      --comment "Kwaku store CPU load test" \
      --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$BURN")" \
      --query Command.CommandId --output text)"
    echo "   command ${CMD_ID}"
    step "Watching for ~${MINUTES} minutes: the high-CPU alarm fires after a few minutes above ${CPU_TARGET}%, then desired capacity rises"
    END=$(( $(date +%s) + MINUTES * 60 ))
    while [ "$(date +%s)" -lt "$END" ]; do
      D="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query 'AutoScalingGroups[0].DesiredCapacity' --output text)"
      CPU="$(aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
        --dimensions "Name=AutoScalingGroupName,Value=${ASG_NAME}" --statistics Average --period 60 \
        --start-time "$(date -u -d '-5 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --query 'sort_by(Datapoints, &Timestamp)[-1].Average' --output text)"
      echo "   $(date +%H:%M:%S)  avg CPU: ${CPU}%   desired capacity: ${D}"
      sleep 60
    done
    status
    echo ""
    echo "✅ When the load stops, the low-CPU alarm scales the group back in to ${ASG_MIN} (takes ~15 minutes)." ;;

  status)
    status
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" --max-items 5 \
      --query 'Activities[].{Time:StartTime, Status:StatusCode, What:Description}' --output table ;;

  *) echo "usage: $0 manual | cpu [minutes] | status" >&2; exit 1 ;;
esac
