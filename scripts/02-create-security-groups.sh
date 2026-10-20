#!/usr/bin/env bash
# Phase 2: two security groups.
#   kwaku-store-alb-sg: HTTP 80 from anywhere          (customers → load balancer)
#   kwaku-store-web-sg: HTTP 80 ONLY from the ALB group (load balancer → web servers)
# No SSH port is opened. Servers are managed through Systems Manager instead.
source "$(dirname "$0")/config.sh"
require VPC_ID

step "Load balancer security group ${ALB_SG_NAME}"
save ALB_SG_ID "$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
  --group-name "$ALB_SG_NAME" --description "Allow public HTTP traffic" \
  --tag-specifications "$(tags security-group "$ALB_SG_NAME")" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTP from the internet"}]' \
  --output text >/dev/null

step "Web server security group ${WEB_SG_NAME}"
save WEB_SG_ID "$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
  --group-name "$WEB_SG_NAME" --description "Allow HTTP from load balancer" \
  --tag-specifications "$(tags security-group "$WEB_SG_NAME")" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=${ALB_SG_ID},Description=\"HTTP from the load balancer only\"}]" \
  --output text >/dev/null

step "Inbound rules"
aws ec2 describe-security-groups --group-ids "$ALB_SG_ID" "$WEB_SG_ID" \
  --query 'SecurityGroups[].{Group:GroupName, Port:IpPermissions[0].FromPort, FromCIDR:IpPermissions[0].IpRanges[0].CidrIp, FromGroup:IpPermissions[0].UserIdGroupPairs[0].GroupId}' \
  --output table

echo ""
echo "Why: customers can only reach the load balancer; only the load balancer can reach the servers."
echo "✅ Security groups ready. Next: ./scripts/03-create-launch-template.sh"
