data "aws_caller_identity" "this" {}

data "aws_partition" "current" {}

data "aws_region" "this" {}

# ----------------------------------------------------------------------------
# Terminate Instances - IAM Resources
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]
    effect = "Allow"

    principals {
      identifiers = ["lambda.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                  = "${var.name_iam_objects}-${var.name}"
  description           = "Role for executing the ${var.name} instance termination function"
  path                  = "/"
  permissions_boundary  = var.role_permissions_boundary
  assume_role_policy    = data.aws_iam_policy_document.assume_role.json
  force_detach_policies = true
  tags                  = var.tags
}


# This IAM policy is used by the Lambda function.
data "aws_iam_policy_document" "lambda" {
  # checkov:skip=CKV_AWS_111:Write access is limited to the resources needed

  # Permit the function to get a list of instances
  statement {
    sid = "GitLabRunnerLifecycleGetInstances"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeRegions",
      "ec2:DescribeInstanceStatus",
    ]
    resources = ["*"]
    effect    = "Allow"
  }

  # Permit the function to terminate instances with the 'gitlab-runner-parent-id'
  # tag.
  statement {
    sid = "GitLabRunnerLifecycleTerminateInstances"
    actions = [
      "ec2:TerminateInstances"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.this.name}:${data.aws_caller_identity.this.account_id}:instance/*"]
    condition {
      test     = "StringLike"
      variable = "ec2:ResourceTag/gitlab-runner-parent-id"
      values   = ["i-*"]
    }
    effect = "Allow"
  }

  # Permit the function to execute the ASG lifecycle action
  statement {
    sid    = "GitLabRunnerLifecycleTerminateEvent"
    effect = "Allow"
    actions = [
      "autoscaling:CompleteLifecycleAction"
    ]
    resources = [var.asg_arn]
  }

  statement {
    sid = "GitLabRunnerLifecycleTerminateLogs"
    actions = [
      "logs:PutLogEvents",
      "logs:CreateLogStream",
    ]
    effect = "Allow"
    # wildcard resources are ok as the log streams are created dynamically during runtime and are not known here
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = [
      aws_cloudwatch_log_group.lambda.arn,
      "${aws_cloudwatch_log_group.lambda.arn}:log-stream:*"
    ]
  }

  statement {
    sid = "SSHKeyHousekeepingList"

    effect = "Allow"
    actions = [
      "ec2:DescribeKeyPairs"
    ]
    resources = ["*"]
  }

  # separate statement due to the condition
  statement {
    sid = "SSHKeyHousekeepingDelete"

    effect = "Allow"
    actions = [
      "ec2:DeleteKeyPair"
    ]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ec2:KeyPairName"
      values   = ["runner-*"]
    }
  }
}

data "aws_iam_policy_document" "spot_request_housekeeping" {
  # checkov:skip=CKV_AWS_111:I didn't found any condition to limit the access.
  # checkov:skip=CKV_AWS_356:False positive and fixed with version 2.3.293

  count  = var.spot_request_enabled ? 1 : 0

  statement {
    sid = "SpotRequestHousekeepingList"

    effect = "Allow"
    actions = [
      "ec2:CancelSpotInstanceRequests",
      "ec2:DescribeSpotInstanceRequests"
    ]
    # I didn't found any condition to limit the access
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda" {
  name   = "${var.name_iam_objects}-${var.name}-lambda"
  path   = "/"
  policy = data.aws_iam_policy_document.lambda.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

resource "aws_iam_policy" "spot_request_housekeeping" {
  count  = var.spot_request_enabled ? 1 : 0

  name   = "${var.name_iam_objects}-${var.name}-cancel-spot"
  path   = "/"
  policy = data.aws_iam_policy_document.spot_request_housekeeping[0].json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "spot_request_housekeeping" {
  count  = var.spot_request_enabled ? 1 : 0

  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.spot_request_housekeeping[0].arn
}
