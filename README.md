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
region is `us-east-1`; set `TF_VAR_aws_region` to use another region and
`TF_VAR_cpu_threshold` to override the threshold. Terraform state and saved
plans can contain the email address, so keep them private.

Click **Confirm subscription** in the AWS SNS email **before** generating load.
CloudWatch sends the notification when the alarm enters `ALARM`; confirming
the subscription after that transition won't replay the alert.

## Generate a CPU spike

1. In the AWS console for the deployment region, open **Systems Manager → Run
   Command**. Choose **Run command** and select `AWS-RunShellScript`. Target
   the instance ID shown by `terraform output -raw instance_id`. If the
   instance isn't listed yet, wait a few minutes for it to register. Your
   console identity also needs permission to send and view Run Command commands.
2. Paste the command below into **Commands** and run it once. It starts one
   CPU worker per vCPU for ten minutes and cleans them up automatically.

   ```sh
   timeout --kill-after=5s 10m bash -c '
     workers=$(nproc)
     for ((i = 0; i < workers; i++)); do
       yes >/dev/null &
     done
     wait
   ' || [ "$?" -eq 124 ]
   ```

3. In **CloudWatch → Alarms**, open the alarm shown by
   `terraform output -raw cpu_alarm_name`. Check that it moves to `ALARM`
   and that the email arrives. Allow several minutes for metric delivery and
   evaluation. After the workers stop, the alarm should return to `OK` as
   below-threshold data arrives.

## Clean up

This demo can incur charges for EC2, storage, the public IPv4 address, detailed
CloudWatch monitoring, and surplus CPU credits. Run `terraform destroy` when
finished (with the same input values), then remove `demo.tfplan`.
