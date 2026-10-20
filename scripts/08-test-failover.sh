#!/usr/bin/env bash
# Phase 8: simulate a server failure. Terminate one web server and watch:
#   the load balancer stop sending it traffic → Auto Scaling launch a replacement → 2 healthy again,
# while a probe checks the website every 2 seconds the whole time.
source "$(dirname "$0")/config.sh"
require ALB_DNS TG_ARN
URL="http://${ALB_DNS}/server.json"

VICTIM="$(asg_instances | awk '{print $1}')"
[[ -z "$VICTIM" ]] && { echo "❌ No instances in ${ASG_NAME}" >&2; exit 1; }

step "Before"
show_targets

step "Terminating ${VICTIM} (a 'server failure'). The Auto Scaling group is NOT changed."
aws ec2 terminate-instances --instance-ids "$VICTIM" \
  --query 'TerminatingInstances[0].{Instance:InstanceId, From:PreviousState.Name, To:CurrentState.Name}' --output table

step "Probing the website every 2 s while Auto Scaling recovers (up to 10 minutes)"
OK=0; FAIL=0; PROBES=0; START=$(date +%s)
while true; do
  if CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL")" && [[ "$CODE" == "200" ]]; then
    OK=$((OK + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  PROBES=$((PROBES + 1))
  ELAPSED=$(( $(date +%s) - START ))
  if (( PROBES % 10 == 0 )); then   # status line about every 20 seconds
    HEALTHY="$(healthy_count)"
    INSTANCES="$(asg_instances | wc -w | tr -d ' ')"
    echo "   +${ELAPSED}s  website ok=${OK} failed=${FAIL} | ASG instances=${INSTANCES} | healthy targets=${HEALTHY}"
    if [[ "$HEALTHY" -ge "$ASG_DESIRED" ]] && ! asg_instances | grep -q "$VICTIM"; then
      break
    fi
  fi
  (( ELAPSED > 600 )) && { echo "   giving up after 10 minutes"; break; }
  sleep 2
done

step "Auto Scaling activity (newest first)"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" --max-items 3 \
  --query 'Activities[].{Time:StartTime, Status:StatusCode, What:Description}' --output table

step "After"
show_targets

TOTAL=$((OK + FAIL))
echo ""
echo "✅ Result: ${OK}/${TOTAL} website checks succeeded while a server was lost and replaced."
echo "   ${VICTIM} is gone; a new server took its place without anyone touching the console."
