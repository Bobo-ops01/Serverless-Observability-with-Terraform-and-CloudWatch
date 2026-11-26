terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    bucket       = "bobo-ops01-tf-cicd-state-use1"
    key          = "observability/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "serverless-observability"
      ManagedBy = "terraform"
    }
  }
}

variable "alert_email" {
  type        = string
  description = "Email address that receives alarm notifications."
}

variable "lambda_functions" {
  type        = list(string)
  default     = ["job-alerts-function"]
  description = "Lambda functions to put on the dashboard and alarm on errors."
}

variable "scheduled_functions" {
  type        = list(string)
  default     = ["job-alerts-function"]
  description = "Functions that should run at least once a day. Alarm if they stop."
}

resource "aws_sns_topic" "alerts" {
  name = "observability-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  for_each = toset(var.lambda_functions)

  alarm_name          = "${each.key}-errors"
  alarm_description   = "${each.key} reported at least one error"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.key }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "not_running" {
  for_each = toset(var.scheduled_functions)

  alarm_name          = "${each.key}-not-running"
  alarm_description   = "${each.key} had no invocations in the last 24 hours"
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = each.key }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

locals {
  widgets = [
    for i, fn in var.lambda_functions : {
      type   = "metric"
      x      = 0
      y      = i * 6
      width  = 24
      height = 6
      properties = {
        title  = fn
        region = "us-east-1"
        view   = "timeSeries"
        stat   = "Sum"
        period = 300
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", fn],
          [".", "Errors", ".", "."],
          [".", "Throttles", ".", "."],
          [".", "Duration", ".", ".", { stat = "Average", yAxis = "right" }],
        ]
      }
    }
  ]
}

resource "aws_cloudwatch_dashboard" "lambdas" {
  dashboard_name = "serverless-observability"
  dashboard_body = jsonencode({ widgets = local.widgets })
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.lambdas.dashboard_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
