terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region containing a default VPC and at least one default subnet."
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email address that will receive the SNS subscription confirmation and CPU alerts."
  type        = string
  sensitive   = true
}

variable "cpu_threshold" {
  description = "CPU utilization percentage above which the alarm fires."
  type        = number
  default     = 70

  validation {
    condition     = var.cpu_threshold > 0 && var.cpu_threshold < 100
    error_message = "The CPU threshold must be greater than 0 and less than 100."
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_partition" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "instance" {
  name_prefix = "cpu-spike-demo-"
  description = "Allow outbound HTTPS for Systems Manager; no inbound rules"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "HTTPS to AWS Systems Manager"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "instance" {
  name_prefix = "cpu-spike-demo-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "cpu-spike-demo-"
  role        = aws_iam_role.instance.name
}

resource "aws_instance" "demo" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  monitoring                  = true

  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = "cpu-spike-demo" }
}

resource "aws_sns_topic" "alerts" {
  name_prefix = "cpu-spike-alerts-"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "cpu-spike-${aws_instance.demo.id}"
  alarm_description   = "Average EC2 CPU exceeds the threshold for two consecutive minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.demo.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_metric_alarm.cpu.arn } }
    }]
  })
}

output "instance_id" {
  value = aws_instance.demo.id
}

output "cpu_alarm_name" {
  value = aws_cloudwatch_metric_alarm.cpu.alarm_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "aws_region" {
  value = var.aws_region
}
