#!/usr/bin/env bash
# Shared settings for every step. Override any value by exporting it before running a script.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-eu-west-2}"          # Europe (London)
export AWS_DEFAULT_REGION="$AWS_REGION"
export PROJECT="${PROJECT:-kwaku-store}"                # name prefix + Project tag on everything
export VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
export SUBNET_A_CIDR="${SUBNET_A_CIDR:-10.0.0.0/20}"
export SUBNET_B_CIDR="${SUBNET_B_CIDR:-10.0.16.0/20}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
export ASG_MIN="${ASG_MIN:-2}"
export ASG_DESIRED="${ASG_DESIRED:-2}"
export ASG_MAX="${ASG_MAX:-4}"
export CPU_TARGET="${CPU_TARGET:-60}"                   # target tracking: average CPU %

# Resource names (as in the console version of the project)
export VPC_NAME="${PROJECT}-vpc"
export ALB_SG_NAME="${PROJECT}-alb-sg"
export WEB_SG_NAME="${PROJECT}-web-sg"
export LAUNCH_TEMPLATE="${PROJECT}-template"
export TARGET_GROUP="${PROJECT}-targets"
export ALB_NAME="${PROJECT}-alb"
export ASG_NAME="${PROJECT}-asg"
export DASHBOARD="${PROJECT}-monitoring"
export INSTANCE_ROLE="${PROJECT}-ec2-role"              # lets Systems Manager run commands (no SSH needed)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_ENV="${ROOT_DIR}/.lab-env"

# IDs created by earlier steps are saved here so later steps can use them
touch "$LAB_ENV"
# shellcheck disable=SC1090
source "$LAB_ENV"

save() {   # save NAME VALUE → remembered for later steps
  grep -v "^export $1=" "$LAB_ENV" > "${LAB_ENV}.tmp" || true
  echo "export $1=\"$2\"" >> "${LAB_ENV}.tmp"
  mv "${LAB_ENV}.tmp" "$LAB_ENV"
  export "$1=$2"
  echo "   $1=$2"
}

require() {
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "❌ ${name} is not set. Run the earlier steps first (see README)." >&2
      exit 1
    fi
  done
}

# Tag specification for `aws ec2 create-*`:  tags <resource-type> <name>
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=${PROJECT}}]"; }

# Instance IDs currently in the Auto Scaling group
asg_instances() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text
}

# Table of targets and their health in the target group
show_targets() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{Instance:Target.Id, AZ:Target.AvailabilityZone, Health:TargetHealth.State, Reason:TargetHealth.Reason}' \
    --output table
}

healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}

step() { echo ""; echo "▶ $*"; }
