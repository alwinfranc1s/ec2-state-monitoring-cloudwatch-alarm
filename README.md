# ec2-state-monitoring-cloudwatch-alarm

Deploy an Amazon Linux 2023 EC2 instance and get an email when its average CPU
utilization exceeds 70% for two consecutive one-minute periods. The threshold
is configurable, and the instance accepts no inbound connections.

## Deploy

You need Terraform and AWS credentials with permissions for EC2, IAM (including
passing the instance role), Systems Manager, CloudWatch, and SNS. Use a region
with a default VPC and at least one default subnet with an internet route, so
the instance can reach Systems Manager over outbound HTTPS.

From the repository root:

```sh
terraform init
terraform plan -out=demo.tfplan
terraform apply demo.tfplan
```

Enter the notification address when prompted for `alert_email`. The default
region is `ap-south-1`; set `TF_VAR_aws_region` to use another region and
`TF_VAR_cpu_threshold` to override the threshold. Terraform state and saved
plans can contain the email address, so keep them private.

## Set up the AWS CLI

Use AWS CLI v2 with credentials for the same AWS account as the deployment.
The CLI identity needs `sns:ConfirmSubscription`, `ssm:DescribeInstanceInformation`,
`ssm:SendCommand`, `ssm:GetCommandInvocation`, `cloudwatch:DescribeAlarms`,
and `cloudwatch:DescribeAlarmHistory`.

In Bash, load the deployment identifiers and region (or set these variables
directly if you already know the values):

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
CPU_ALARM_NAME=$(terraform output -raw cpu_alarm_name)
SNS_TOPIC_ARN=$(terraform output -raw sns_topic_arn)
AWS_REGION=$(terraform output -raw aws_region)
export AWS_REGION
export AWS_PAGER=""
```

Before generating load, copy the `Token` query parameter value from the
**Confirm subscription** link in the SNS email. You don't need to open the link.
Paste the token when prompted and check that the command returns a subscription
ARN:

```bash
read -r -s -p 'SNS confirmation token: ' SNS_TOKEN
printf '\n'
aws sns confirm-subscription --topic-arn "$SNS_TOPIC_ARN" --token "$SNS_TOKEN" \
  --query 'SubscriptionArn' --output text
unset SNS_TOKEN
```

CloudWatch sends the email when the alarm enters `ALARM`; confirming the
subscription after that transition won't replay the alert.

## Generate a CPU spike

Check that Systems Manager reports the instance as `Online`. If it isn't
listed yet, wait a few minutes and try again.

```bash
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' --output text
```

Send the command once. It runs one CPU worker per vCPU for ten minutes and
stops them automatically.

```bash
COMMAND_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "$(cat <<'JSON'
{
  "commands": [
    "timeout --kill-after=5s 10m bash -c '",
    "  workers=$(nproc)",
    "  for ((i = 0; i < workers; i++)); do",
    "    yes >/dev/null &",
    "  done",
    "  wait",
    "' || [ \"$?\" -eq 124 ]"
  ]
}
JSON
)" --query 'Command.CommandId' --output text)
printf 'Run Command ID: %s\n' "$COMMAND_ID"
```

Check the command status. If it returns `InvocationDoesNotExist`, retry
after a few seconds while Systems Manager records the invocation.

```bash
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,ExitCode:ResponseCode,Errors:StandardErrorContent}' --output json
```

## Monitor the CloudWatch alarm

Check the alarm's current state and the reason for its last transition:

```bash
aws cloudwatch describe-alarms --alarm-names "$CPU_ALARM_NAME" \
  --query 'MetricAlarms[].{State:StateValue,Since:StateTransitionedTimestamp,Reason:StateReason}' \
  --output json
```

Allow several minutes for the alarm to enter `ALARM` and for the email to
arrive. After the workers stop, the alarm should return to `OK` as
below-threshold metrics arrive. If you miss a transition, check the history:

```bash
aws cloudwatch describe-alarm-history --alarm-name "$CPU_ALARM_NAME" \
  --history-item-type StateUpdate --max-items 5 \
  --query 'AlarmHistoryItems[].{Time:Timestamp,Change:HistorySummary}' --output table
```

## Clean up

This demo can incur charges for EC2, storage, the public IPv4 address, detailed
CloudWatch monitoring, and surplus CPU credits. Run `terraform destroy` when
finished (with the same input values), then remove `demo.tfplan`.
