terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "primary" {
  backend = "local"

  config = {
    path = var.primary_state_path
  }
}

data "terraform_remote_state" "standby" {
  backend = "local"

  config = {
    path = var.standby_state_path
  }
}

# --- Route53 Failover DNS (requires domain) ---

resource "aws_route53_zone" "main" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name

  tags = {
    Name = "${var.project_name}-zone"
  }
}

resource "aws_route53_record" "primary" {
  count = var.domain_name != "" ? 1 : 0

  zone_id        = aws_route53_zone.main[0].zone_id
  name           = var.app_subdomain != "" ? "${var.app_subdomain}.${var.domain_name}" : var.domain_name
  type           = "A"
  set_identifier = "primary"

  alias {
    name                   = var.primary_nlb_dns_name != "" ? var.primary_nlb_dns_name : data.terraform_remote_state.primary.outputs.primary_nlb_dns_name
    zone_id                = var.primary_nlb_zone_id != "" ? var.primary_nlb_zone_id : data.terraform_remote_state.primary.outputs.primary_nlb_zone_id
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary[0].id
}

resource "aws_route53_record" "standby" {
  count = var.domain_name != "" ? 1 : 0

  zone_id        = aws_route53_zone.main[0].zone_id
  name           = var.app_subdomain != "" ? "${var.app_subdomain}.${var.domain_name}" : var.domain_name
  type           = "A"
  set_identifier = "standby"

  alias {
    name                   = var.standby_nlb_dns_name != "" ? var.standby_nlb_dns_name : data.terraform_remote_state.standby.outputs.standby_nlb_dns_name
    zone_id                = var.standby_nlb_zone_id != "" ? var.standby_nlb_zone_id : data.terraform_remote_state.standby.outputs.standby_nlb_zone_id
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "SECONDARY"
  }
}

resource "aws_route53_health_check" "primary" {
  count = var.domain_name != "" ? 1 : 0

  fqdn              = var.primary_health_check_fqdn != "" ? var.primary_health_check_fqdn : data.terraform_remote_state.primary.outputs.primary_nlb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "${var.project_name}-primary-health"
  }
}

# --- Lambda Witness ---

resource "aws_iam_role" "witness_lambda" {
  name = "${var.project_name}-witness-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "witness_lambda" {
  name = "${var.project_name}-witness-policy"
  role = aws_iam_role.witness_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.failover.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.failover.arn
      }
    ]
  })
}

resource "aws_lambda_function" "witness" {
  filename         = data.archive_file.witness_lambda.output_path
  function_name    = "${var.project_name}-witness"
  role             = aws_iam_role.witness_lambda.arn
  handler          = "health_check.handler"
  source_code_hash = data.archive_file.witness_lambda.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      PRIMARY_API_URL        = var.primary_api_url != "" ? var.primary_api_url : "https://${values(data.terraform_remote_state.primary.outputs.primary_control_plane_ips)[0]}:6443"
      FAILURE_THRESHOLD      = "3"
      STATE_TABLE            = aws_dynamodb_table.witness_state.name
      FAILOVER_STATE_MACHINE = aws_sfn_state_machine.failover.arn
      SNS_TOPIC_ARN          = aws_sns_topic.failover.arn
    }
  }
}

data "archive_file" "witness_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/health_check.py"
  output_path = "${path.module}/lambda/health_check.zip"
}

resource "aws_cloudwatch_event_rule" "witness_schedule" {
  name                = "${var.project_name}-witness-schedule"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "witness" {
  rule      = aws_cloudwatch_event_rule.witness_schedule.name
  target_id = "witness-lambda"
  arn       = aws_lambda_function.witness.arn
}

resource "aws_lambda_permission" "witness_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.witness.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.witness_schedule.arn
}

# --- Witness State (DynamoDB) ---

resource "aws_dynamodb_table" "witness_state" {
  name         = "${var.project_name}-witness-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

# --- SNS Notifications ---

resource "aws_sns_topic" "failover" {
  name = "${var.project_name}-failover-alerts"
}

resource "aws_sns_topic_subscription" "failover_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.failover.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Step Functions Failover Workflow ---

resource "aws_iam_role" "step_functions" {
  name = "${var.project_name}-sfn-failover"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "step_functions" {
  name = "${var.project_name}-sfn-policy"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.failover.arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "failover" {
  name     = "${var.project_name}-failover"
  role_arn = aws_iam_role.step_functions.arn

  definition = templatefile("${path.module}/step_functions/failover.asl.json", {
    sns_topic_arn = aws_sns_topic.failover.arn
  })
}
