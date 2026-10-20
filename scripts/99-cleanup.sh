#!/usr/bin/env bash
# Phase 12: delete everything, in dependency order:
#   Auto Scaling group (terminates servers) → load balancer → target group → launch template →
#   dashboard, alarms, SNS → IAM role → security groups → subnets, route table, internet gateway → VPC
# Resources are found by name/tag, so this works even without .lab-env. Safe to run again.
source "$(dirname "$0")/config.sh"
set +e

step "Auto Scaling group ${ASG_NAME} (scale to 0, then delete with its instances)"
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
     --query 'length(AutoScalingGroups)' --output text | grep -q 1; then
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --min-size 0 --desired-capacity 0
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete
  for _ in $(seq 40); do
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
      --query 'length(AutoScalingGroups)' --output text | grep -q 0 && break
    echo "   waiting for the group and its instances to be deleted..."; sleep 15
  done
fi

step "Load balancer ${ALB_NAME}"
ALB_ARN="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)"
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" && echo "   deleted"
fi

step "Target group ${TARGET_GROUP}"
TG_ARN="$(aws elbv2 describe-target-groups --names "$TARGET_GROUP" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
[[ -n "$TG_ARN" && "$TG_ARN" != "None" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN" && echo "   deleted"

step "Launch template ${LAUNCH_TEMPLATE}"
aws ec2 delete-launch-template --launch-template-name "$LAUNCH_TEMPLATE" --output text >/dev/null 2>&1 && echo "   deleted"

step "CloudWatch dashboard, alarms and SNS topic"
aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD" 2>/dev/null && echo "   dashboard deleted"
aws cloudwatch delete-alarms --alarm-names "${PROJECT}-unhealthy-hosts" 2>/dev/null && echo "   alarm deleted"
for topic in $(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${PROJECT}-alerts')].TopicArn" --output text); do
  aws sns delete-topic --topic-arn "$topic" && echo "   topic deleted"
done
# (the target tracking alarms are deleted automatically with the Auto Scaling group)

step "Instance role and profile ${INSTANCE_ROLE}"
if aws iam get-role --role-name "$INSTANCE_ROLE" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_ROLE" --role-name "$INSTANCE_ROLE"
  aws iam delete-instance-profile --instance-profile-name "$INSTANCE_ROLE"
  aws iam detach-role-policy --role-name "$INSTANCE_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam delete-role --role-name "$INSTANCE_ROLE" && echo "   deleted"
fi

VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=${PROJECT}" --query 'Vpcs[0].VpcId' --output text)"
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  step "Waiting for instances in ${VPC_ID} to terminate"
  for _ in $(seq 30); do
    N="$(aws ec2 describe-instances --filters "Name=vpc-id,Values=${VPC_ID}" \
      "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
      --query 'length(Reservations[].Instances[])' --output text)"
    [[ "$N" == "0" ]] && break
    echo "   ${N} instance(s) still shutting down..."; sleep 10
  done

  step "Security groups (web first: it references the ALB group)"
  for name in "$WEB_SG_NAME" "$ALB_SG_NAME"; do
    SG="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" \
      --query 'SecurityGroups[0].GroupId' --output text)"
    if [[ -n "$SG" && "$SG" != "None" ]]; then
      for _ in $(seq 12); do
        aws ec2 delete-security-group --group-id "$SG" 2>/dev/null && { echo "   deleted ${name}"; break; }
        echo "   ${name} still in use (network interfaces releasing), retrying..."; sleep 10
      done
    fi
  done

  step "Route table, subnets, internet gateway, VPC"
  for assoc in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query 'RouteTables[].Associations[?!Main].RouteTableAssociationId' --output text); do
    aws ec2 disassociate-route-table --association-id "$assoc"
  done
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$rt" && echo "   deleted ${rt}"
  done
  for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$subnet" && echo "   deleted ${subnet}"
  done
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
      --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" && echo "   deleted ${igw}"
  done
  aws ec2 delete-vpc --vpc-id "$VPC_ID" && echo "   deleted ${VPC_ID}"
else
  echo ""
  echo "   no VPC tagged Project=${PROJECT}"
fi

rm -f "$LAB_ENV"
echo ""
echo "✅ Done. Double-check: EC2 → Instances, EC2 → Load Balancers, VPC, and Billing and Cost Management."
