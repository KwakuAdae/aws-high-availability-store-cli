#!/usr/bin/env bash
# Phase 10: CloudWatch monitoring.
#   - dashboard kwaku-store-monitoring: healthy hosts, requests, response time, 5xx, capacity, CPU
#   - alarm: fewer than 2 healthy servers for 2 minutes (emails you if ALERT_EMAIL is set)
#   ALERT_EMAIL=you@example.com ./scripts/10-create-dashboard.sh
source "$(dirname "$0")/config.sh"
require ALB_ARN TG_ARN

# CloudWatch identifies the ALB and target group by the last part of their ARNs
export ALB_DIM="${ALB_ARN#*:loadbalancer/}"     # app/kwaku-store-alb/1234567890abcdef
export TG_DIM="${TG_ARN##*:}"                   # targetgroup/kwaku-store-targets/abcdef1234567890

step "Dashboard ${DASHBOARD}"
BODY="$(python3 - "$ROOT_DIR/monitoring/dashboard.json" <<'PY'
import json, os, sys
text = open(sys.argv[1]).read()
for key in ("AWS_REGION", "ALB_DIM", "TG_DIM", "ASG_NAME", "ALB_NAME"):
    text = text.replace("${" + key + "}", os.environ[key])
print(json.dumps(json.loads(text)))
PY
)"
aws cloudwatch put-dashboard --dashboard-name "$DASHBOARD" --dashboard-body "$BODY" \
  --query 'DashboardValidationMessages' --output text

ACTIONS=()
if [[ -n "${ALERT_EMAIL:-}" ]]; then
  step "SNS topic ${PROJECT}-alerts → ${ALERT_EMAIL} (confirm the subscription email AWS sends you)"
  save TOPIC_ARN "$(aws sns create-topic --name "${PROJECT}-alerts" --tags "Key=Project,Value=${PROJECT}" --query TopicArn --output text)"
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" --output text >/dev/null
  ACTIONS=(--alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN")
fi

step "Alarm ${PROJECT}-unhealthy-hosts: HealthyHostCount < ${ASG_MIN} for 2 minutes"
aws cloudwatch put-metric-alarm --alarm-name "${PROJECT}-unhealthy-hosts" \
  --alarm-description "Fewer than ${ASG_MIN} healthy web servers behind ${ALB_NAME}" \
  --namespace AWS/ApplicationELB --metric-name HealthyHostCount \
  --dimensions "Name=LoadBalancer,Value=${ALB_DIM}" "Name=TargetGroup,Value=${TG_DIM}" \
  --statistic Minimum --period 60 --evaluation-periods 2 --datapoints-to-alarm 2 \
  --threshold "$ASG_MIN" --comparison-operator LessThanThreshold --treat-missing-data breaching \
  "${ACTIONS[@]}"

aws cloudwatch describe-alarms --alarm-name-prefix "$PROJECT" --query 'MetricAlarms[].{Alarm:AlarmName, State:StateValue}' --output table

echo ""
echo "✅ Open: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards/dashboard/${DASHBOARD}"
echo "   Metrics appear after a few minutes. Run 08-test-failover.sh again and watch HealthyHostCount dip."
