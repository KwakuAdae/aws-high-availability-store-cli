#!/usr/bin/env bash
# Phase 3: the launch template: the recipe Auto Scaling uses for every new web server.
#   Amazon Linux 2023 (latest AMI), t3.micro, no key pair, web security group, public IP,
#   IMDSv2 required, user data = website/user-data.sh, and an instance profile for Systems Manager.
source "$(dirname "$0")/config.sh"
require WEB_SG_ID

step "Latest Amazon Linux 2023 AMI (from the public SSM parameter, always current)"
save AMI_ID "$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)"

step "Instance role ${INSTANCE_ROLE} (Systems Manager access: run commands without SSH or key pairs)"
if ! aws iam get-role --role-name "$INSTANCE_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$INSTANCE_ROLE" \
    --assume-role-policy-document "file://${ROOT_DIR}/iam/ec2-trust-policy.json" \
    --description "Kwaku Online Store web servers" \
    --tags "Key=Project,Value=${PROJECT}" --output text --query Role.Arn >/dev/null
  aws iam attach-role-policy --role-name "$INSTANCE_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_ROLE" --output text >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_ROLE" --role-name "$INSTANCE_ROLE"
  echo "   created (waiting 15 s for IAM to propagate)"; sleep 15
else
  echo "   already exists, reusing it"
fi

step "Launch template ${LAUNCH_TEMPLATE}"
DATA_FILE="$(mktemp)"
python3 - "$ROOT_DIR/website/user-data.sh" > "$DATA_FILE" <<'PY'
import base64, json, os, sys
user_data = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
print(json.dumps({
    "ImageId": os.environ["AMI_ID"],
    "InstanceType": os.environ["INSTANCE_TYPE"],
    "IamInstanceProfile": {"Name": os.environ["INSTANCE_ROLE"]},
    # Device 0 with a public IP so servers in public subnets can download NGINX (no NAT gateway)
    "NetworkInterfaces": [{
        "DeviceIndex": 0,
        "AssociatePublicIpAddress": True,
        "Groups": [os.environ["WEB_SG_ID"]],
        "DeleteOnTermination": True,
    }],
    # IMDSv2 only: the metadata service requires a session token (blocks SSRF-style attacks)
    "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled", "HttpPutResponseHopLimit": 1},
    "Monitoring": {"Enabled": False},
    "UserData": user_data,
    "TagSpecifications": [
        {"ResourceType": "instance", "Tags": [
            {"Key": "Name", "Value": os.environ["PROJECT"] + "-web"},
            {"Key": "Project", "Value": os.environ["PROJECT"]}]},
        {"ResourceType": "volume", "Tags": [{"Key": "Project", "Value": os.environ["PROJECT"]}]},
    ],
}))
PY
save LT_ID "$(aws ec2 create-launch-template --launch-template-name "$LAUNCH_TEMPLATE" \
  --version-description "Web server for online store" \
  --launch-template-data "file://${DATA_FILE}" \
  --tag-specifications "$(tags launch-template "$LAUNCH_TEMPLATE")" \
  --query LaunchTemplate.LaunchTemplateId --output text)"
rm -f "$DATA_FILE"

aws ec2 describe-launch-template-versions --launch-template-id "$LT_ID" --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.{AMI:ImageId, Type:InstanceType, Profile:IamInstanceProfile.Name, IMDSv2:MetadataOptions.HttpTokens}' \
  --output table

echo ""
echo "✅ Launch template ready. Next: ./scripts/04-create-target-group.sh"
