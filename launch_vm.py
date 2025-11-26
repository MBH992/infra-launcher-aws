import os
import uuid
import base64
from typing import List, Optional

import boto3
from botocore.exceptions import ClientError

# --- Configuration from Environment Variables ---
AWS_REGION = os.getenv("AWS_REGION")
PROJECT_PREFIX = os.getenv("PROJECT_PREFIX", "learn-k8s")
USER_BASE_SG_ID = os.getenv("USER_BASE_SG_ID")
USER_SUBNET_ID = os.getenv("USER_SUBNET_ID")
USER_INSTANCE_TYPE = os.getenv("USER_INSTANCE_TYPE", "t3.small")
USER_KEY_NAME = os.getenv("USER_KEY_NAME")
USER_AMI_ID = os.getenv("USER_AMI_ID")
PROXY_IP = os.getenv("PROXY_IP")
DEBUG_SSH_CIDR = os.getenv("DEBUG_SSH_CIDR", "")

if not all([AWS_REGION, USER_SUBNET_ID, USER_KEY_NAME, USER_AMI_ID, PROXY_IP]):
    raise ValueError("Missing required AWS configuration environment variables")

PROXY_CIDR = f"{PROXY_IP}/32"

ec2_client = boto3.client("ec2", region_name=AWS_REGION)

def _session_security_group_name(session_id: str) -> str:
    return f"{PROJECT_PREFIX}-user-{session_id}-sg"


def _render_user_cloud_init(session_id: str) -> str:
    with open("templates/user-vm-cloud-init.tpl.sh", "r", encoding="utf-8") as fh:
        template = fh.read()
    return template.replace("{{SESSION_ID}}", session_id).replace("{{PROXY_IP}}", PROXY_IP)


def _create_session_security_group(session_id: str) -> str:
    response = ec2_client.describe_subnets(SubnetIds=[USER_SUBNET_ID])
    vpc_id = response["Subnets"][0]["VpcId"]

    group_name = _session_security_group_name(session_id)
    sg_response = ec2_client.create_security_group(
        GroupName=group_name,
        Description=f"User session SG for {session_id}",
        VpcId=vpc_id,
        TagSpecifications=[
            {
                "ResourceType": "security-group",
                "Tags": [
                    {"Key": "session_id", "Value": session_id},
                    {"Key": "created_by", "Value": "infra-launcher"},
                    {"Key": "project", "Value": PROJECT_PREFIX},
                ],
            }
        ],
    )
    sg_id = sg_response["GroupId"]

    try:
        ec2_client.authorize_security_group_ingress(
            GroupId=sg_id,
            IpPermissions=[
                {
                    "IpProtocol": "tcp",
                    "FromPort": 8889,
                    "ToPort": 8889,
                    "IpRanges": [
                        {
                            "CidrIp": PROXY_CIDR,
                            "Description": "Proxy websocket tunnel",
                        }
                    ],
                }
            ],
        )
        if DEBUG_SSH_CIDR:
            print(f"⚠️ [TEST ONLY] Allowing temporary SSH from {DEBUG_SSH_CIDR}")
            ec2_client.authorize_security_group_ingress(
                GroupId=sg_id,
                IpPermissions=[
                    {
                        "IpProtocol": "tcp",
                        "FromPort": 22,
                        "ToPort": 22,
                        "IpRanges": [
                            {
                                "CidrIp": DEBUG_SSH_CIDR,
                                "Description": "TEST ONLY - temporary SSH access",
                            }
                        ],
                    }
                ],
            )
    except ClientError as exc:
        # Rollback SG if rule creation fails
        try:
            ec2_client.delete_security_group(GroupId=sg_id)
        except ClientError:
            pass
        raise RuntimeError(f"Failed to authorise security group ingress: {exc}")

    return sg_id


def _wait_for_instance_state(instance_ids: List[str], state: str) -> None:
    waiter = ec2_client.get_waiter(f"instance_{state}")
    waiter.wait(InstanceIds=instance_ids)


def launch_user_vm():
    session_id = str(uuid.uuid4())[:8]
    print(f"🚀 Launching AWS session {session_id}")

    user_data = _render_user_cloud_init(session_id)
    encoded_user_data = base64.b64encode(user_data.encode("utf-8")).decode("utf-8")

    user_sg_id = None
    instance_id: Optional[str] = None

    try:
        user_sg_id = _create_session_security_group(session_id)

        network_interface = {
            "DeviceIndex": 0,
            "SubnetId": USER_SUBNET_ID,
            "Groups": [gid for gid in [user_sg_id, USER_BASE_SG_ID] if gid],
            "AssociatePublicIpAddress": False,
        }

        response = ec2_client.run_instances(
            ImageId=USER_AMI_ID,
            InstanceType=USER_INSTANCE_TYPE,
            KeyName=USER_KEY_NAME,
            MinCount=1,
            MaxCount=1,
            NetworkInterfaces=[network_interface],
            TagSpecifications=[
                {
                    "ResourceType": "instance",
                    "Tags": [
                        {"Key": "Name", "Value": f"{PROJECT_PREFIX}-uservm-{session_id}"},
                        {"Key": "session_id", "Value": session_id},
                        {"Key": "created_by", "Value": "infra-launcher"},
                    ],
                },
                {
                    "ResourceType": "volume",
                    "Tags": [
                        {"Key": "session_id", "Value": session_id},
                        {"Key": "created_by", "Value": "infra-launcher"},
                    ],
                },
            ],
            UserData=encoded_user_data,
        )

        instance = response["Instances"][0]
        instance_id = instance["InstanceId"]
        print(f"✅ Instance {instance_id} requested. Waiting for running state…")
        _wait_for_instance_state([instance_id], "running")

        instance_desc = ec2_client.describe_instances(InstanceIds=[instance_id])
        reservations = instance_desc.get("Reservations", [])
        if not reservations or not reservations[0]["Instances"]:
            raise RuntimeError("Failed to retrieve instance details after launch")

        private_ip = reservations[0]["Instances"][0]["PrivateIpAddress"]
        print(f"🎯 Session {session_id} private IP: {private_ip}")
        return session_id, private_ip

    except Exception as exc:
        print(f"❌ Failed to launch AWS session {session_id}: {exc}")
        if instance_id:
            try:
                delete_user_vm(session_id)
            except Exception as cleanup_error:
                print(f"⚠️ Failed to clean up instance during rollback: {cleanup_error}")
        else:
            if user_sg_id:
                try:
                    ec2_client.delete_security_group(GroupId=user_sg_id)
                    print(f"🧹 Deleted security group {user_sg_id} after failure")
                except ClientError as sg_error:
                    print(f"⚠️ Could not delete security group {user_sg_id}: {sg_error}")
        raise


def _find_instance_ids(session_id: str) -> List[str]:
    response = ec2_client.describe_instances(
        Filters=[
            {"Name": "tag:session_id", "Values": [session_id]},
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopping", "stopped"],
            },
        ]
    )

    instance_ids: List[str] = []
    for reservation in response.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            instance_ids.append(instance["InstanceId"])
    return instance_ids


def delete_user_vm(session_id):
    print(f"🗑️ Deleting AWS resources for session: {session_id}")

    instance_ids = _find_instance_ids(session_id)
    if instance_ids:
        try:
            print(f"   - Terminating instances: {instance_ids}")
            ec2_client.terminate_instances(InstanceIds=instance_ids)
            _wait_for_instance_state(instance_ids, "terminated")
            print("   - Instances terminated")
        except ClientError as exc:
            raise RuntimeError(f"Failed to terminate instances for session {session_id}: {exc}")

    # Delete the per-session security group
    sg_name = _session_security_group_name(session_id)
    try:
        response = ec2_client.describe_security_groups(GroupNames=[sg_name])
        sg_id = response["SecurityGroups"][0]["GroupId"]
        ec2_client.delete_security_group(GroupId=sg_id)
        print(f"   - Security group {sg_name} deleted")
    except ClientError as exc:
        error_code = exc.response["Error"].get("Code")
        if error_code not in {"InvalidGroup.NotFound", "InvalidGroupId.NotFound"}:
            raise RuntimeError(f"Failed to delete security group {sg_name}: {exc}")

    print(f"✅ Cleanup complete for session {session_id}")


if __name__ == "__main__":
    sid, ip = launch_user_vm()
    print(f"Session ID: {sid}")
    print(f"Private IP: {ip}")
