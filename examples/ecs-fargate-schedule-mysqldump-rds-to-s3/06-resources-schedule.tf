#################
# IAM resources #
#################

resource "aws_iam_user" "task_user" {
  name = "${var.sys_name}-task-user"
  path = "/"
}

resource "aws_iam_access_key" "task_user_access_key" {
  user = aws_iam_user.task_user.name
}

resource "aws_iam_policy" "task_user_s3_policy" {
  name = "${var.sys_name}-task-user-s3-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VisualEditor0"
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = [
          "arn:aws:s3:::${module.tgt_data_bucket.bucket.bucket}",
          "arn:aws:s3:::${module.tgt_data_bucket.bucket.bucket}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "task_user_s3_policy_attachment" {
  user       = aws_iam_user.task_user.name
  policy_arn = aws_iam_policy.task_user_s3_policy.arn
}

################################
# ECS Scheduled task resources #
################################

#-----------------------#
# CloudWatch event role #
#-----------------------#

data "aws_iam_policy_document" "app_scheduled_task_cw_event_role_assume_role_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["events.amazonaws.com"]
      type        = "Service"
    }
  }
}

data "aws_iam_policy_document" "app_scheduled_task_cw_event_role_cloudwatch_policy" {
  statement {
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.app_cluster.arn]
    }
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = ["${aws_iam_role.app_ecsTaskExecutionRole.arn}"]
  }
}

resource "aws_iam_role" "app_scheduled_task_cw_event_role" {
  name               = "${var.sys_name}-app-cw-role"
  assume_role_policy = data.aws_iam_policy_document.app_scheduled_task_cw_event_role_assume_role_policy.json
}

resource "aws_iam_role_policy" "app_scheduled_task_cw_event_role_cloudwatch_policy" {
  name   = "${var.sys_name}-app-cw-policy"
  role   = aws_iam_role.app_scheduled_task_cw_event_role.id
  policy = data.aws_iam_policy_document.app_scheduled_task_cw_event_role_cloudwatch_policy.json
}

#-----------------------#
# CloudWatch event rule #
#-----------------------#

resource "aws_cloudwatch_event_rule" "app_event_rule" {
  name                = "${var.sys_name}-app-cw-event-rule"
  schedule_expression = "${var.app_schedule_expression}"
  is_enabled          = true
  tags = {
    Name = "${var.sys_name}-app-cw-event-rule"
  }
}

#-------------------------#
# CloudWatch event target #
#-------------------------#

resource "aws_cloudwatch_event_target" "app_ecs_scheduled_task" {
  rule           = aws_cloudwatch_event_rule.app_event_rule.name
  event_bus_name = aws_cloudwatch_event_rule.app_event_rule.event_bus_name
  target_id      = aws_ecs_cluster.app_cluster.name
  arn            = aws_ecs_cluster.app_cluster.arn
  role_arn       = aws_iam_role.app_scheduled_task_cw_event_role.arn
  
  input = <<DOC
{
  "containerOverrides": [{
    "name": "${var.sys_name}-app-task",
    "command": ["${var.app_command}"],
    "environment": [
      {"name": "AWS_ACCESS_KEY_ID", "value": "${aws_iam_access_key.task_user_access_key.id}"},
      {"name": "AWS_SECRET_ACCESS_KEY", "value": "${aws_iam_access_key.task_user_access_key.secret}"},
      {"name": "AWS_REGION", "value": "${var.aws_region}"},
      {"name": "MYSQL_ALLOW_EMPTY_PASSWORD", "value": "yes"},
      {"name": "MYSQL_HOST", "value": "${aws_db_instance.src_data_dbi.address}"},
      {"name": "MYSQL_DB_NAME", "value": "${aws_db_instance.src_data_dbi.db_name}"},
      {"name": "MYSQL_PORT", "value": "${aws_db_instance.src_data_dbi.port}"},
      {"name": "MYSQL_USERNAME", "value": "${aws_db_instance.src_data_dbi.username}"},
      {"name": "MYSQL_PASSWORD", "value": "${var.data_master_db_password}"},
      {"name": "MYSQL_SSL_MODE", "value": "DISABLED"},
      {"name": "AWS_S3_BUCKET_NAME", "value": "${module.tgt_data_bucket.bucket.bucket}"}
    ],
    "environmentFiles": []
  }]
}
DOC

  ecs_target {
    launch_type         = "FARGATE"
    platform_version    = "LATEST"
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.app_taskdef.arn
    
    network_configuration {
      subnets          = [for s in aws_subnet.sys_public_subnets: "${s.id}"]
      security_groups  = ["${aws_security_group.app_sg.id}"]
      
      # IMPORTANT: 
      # For Auto-assign Public IP, choose whether to have your tasks receive a public IP address. 
      # For tasks on Fargate, for the task to pull the container image, 
      # - it must either use a public subnet and be assigned a public IP address 
      # - or a private subnet that has a route to the internet or a NAT gateway that can route requests to the internet.
      # So, inside the public subnet of this project, 
      # it is required to be true to ECS Scheduled Task to pull image from ECR Private Repository.
      assign_public_ip = true  
    }
  }
}
