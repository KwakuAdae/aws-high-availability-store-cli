#!/usr/bin/env bash
# Phase 1: the network. A VPC with two PUBLIC subnets in two Availability Zones and an
# internet gateway. No NAT gateway and no private subnets: this keeps the lab cheap.
source "$(dirname "$0")/config.sh"

if [[ -n "${VPC_ID:-}" ]]; then
  echo "VPC ${VPC_ID} already exists (from .lab-env). Nothing to do."
  exit 0
fi

step "Caller identity and region"
aws sts get-caller-identity --query '{Account:Account, Arn:Arn}' --output table
echo "   Region: ${AWS_REGION}"

step "Picking two Availability Zones"
read -r AZ_A AZ_B < <(aws ec2 describe-availability-zones \
  --filters Name=state,Values=available Name=zone-type,Values=availability-zone \
  --query 'AvailabilityZones[0:2].ZoneName' --output text)
save AZ_A "$AZ_A"
save AZ_B "$AZ_B"

step "VPC ${VPC_NAME} (${VPC_CIDR}) with DNS resolution and DNS hostnames"
save VPC_ID "$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "$(tags vpc "$VPC_NAME")" --query Vpc.VpcId --output text)"
aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

step "Internet gateway"
save IGW_ID "$(aws ec2 create-internet-gateway \
  --tag-specifications "$(tags internet-gateway "${PROJECT}-igw")" \
  --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

step "Two public subnets"
save SUBNET_A "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" --tag-specifications "$(tags subnet "${PROJECT}-public-${AZ_A}")" \
  --query Subnet.SubnetId --output text)"
save SUBNET_B "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" --tag-specifications "$(tags subnet "${PROJECT}-public-${AZ_B}")" \
  --query Subnet.SubnetId --output text)"
for s in "$SUBNET_A" "$SUBNET_B"; do
  aws ec2 modify-subnet-attribute --subnet-id "$s" --map-public-ip-on-launch
done

step "Public route table: 0.0.0.0/0 → internet gateway"
save RT_ID "$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags route-table "${PROJECT}-public-rt")" \
  --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" --output text >/dev/null
for s in "$SUBNET_A" "$SUBNET_B"; do
  aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$s" --output text >/dev/null
done

step "Verify"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value, CIDR:CidrBlock, AZ:AvailabilityZone, PublicIP:MapPublicIpOnLaunch}' \
  --output table
aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes[].{Destination:DestinationCidrBlock, Target:GatewayId}' --output table

echo ""
echo "✅ Network ready. Next: ./scripts/02-create-security-groups.sh"
