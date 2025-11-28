terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # use the profile we created: secure-sharing
  shared_credentials_files = ["~/.aws/credentials"]
  profile                  = "secure-sharing"
}

# ---------- S3 bucket for file storage ----------
resource "aws_s3_bucket" "files" {
  bucket = var.s3_bucket_name
}

# Block all public access (very important for security)
resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning (helps with accidental deletes/overwrites)
resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Default encryption (good practice)
resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- DynamoDB tables ----------

# Table for file metadata
resource "aws_dynamodb_table" "files" {
  name         = "${var.project_prefix}-files"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "file_id"

  attribute {
    name = "file_id"
    type = "S"
  }
}

# Table for audit logs
resource "aws_dynamodb_table" "audit" {
  name         = "${var.project_prefix}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "audit_id"

  attribute {
    name = "audit_id"
    type = "S"
  }
}

# ---------- IAM role for presigner Lambda ----------

resource "aws_iam_role" "lambda_presigner" {
  name = "${var.project_prefix}-presigner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Attach basic Lambda logging permissions
resource "aws_iam_role_policy_attachment" "lambda_presigner_logs" {
  role       = aws_iam_role.lambda_presigner.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline policy: S3 + DynamoDB access
resource "aws_iam_role_policy" "lambda_presigner_policy" {
  name = "${var.project_prefix}-presigner-policy"
  role = aws_iam_role.lambda_presigner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3GetObject"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.files.arn}/*"
      },
      {
        Sid    = "DynamoDBAuditWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.audit.arn
      }
    ]
  })
}

# ---------- IAM role for uploader Lambda ----------

resource "aws_iam_role" "lambda_uploader" {
  name = "${var.project_prefix}-uploader-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_uploader_logs" {
  role       = aws_iam_role.lambda_uploader.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_uploader_policy" {
  name = "${var.project_prefix}-uploader-policy"
  role = aws_iam_role.lambda_uploader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3PutObject"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.files.arn}/*"
      },
      {
        Sid    = "DynamoDBAuditWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.audit.arn
      }
    ]
  })
}

# ---------- Lambda function: presigner ----------

resource "aws_lambda_function" "presigner" {
  function_name = "${var.project_prefix}-presigner"
  role          = aws_iam_role.lambda_presigner.arn

  runtime = "python3.11"
  handler = "app.lambda_handler"

  filename         = "${path.module}/../build/presigner.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/presigner.zip")

  timeout = 10

  environment {
    variables = {
      FILES_BUCKET = aws_s3_bucket.files.bucket
      AUDIT_TABLE  = aws_dynamodb_table.audit.name
    }
  }
}

# ---------- Lambda function: uploader ----------

resource "aws_lambda_function" "uploader" {
  function_name = "${var.project_prefix}-uploader"
  role          = aws_iam_role.lambda_uploader.arn

  runtime = "python3.11"
  handler = "app.lambda_handler"

  filename         = "${path.module}/../build/uploader.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/uploader.zip")

  timeout = 10

  environment {
    variables = {
      FILES_BUCKET = aws_s3_bucket.files.bucket
      AUDIT_TABLE  = aws_dynamodb_table.audit.name
    }
  }
}

# ---------- API Gateway HTTP API ----------

resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_prefix}-http-api"
  protocol_type = "HTTP"
}

# ---------- Cognito User Pool & Client ----------

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_prefix}-user-pool"

  username_attributes       = ["email"]
  auto_verified_attributes  = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "${var.project_prefix}-app-client"
  user_pool_id = aws_cognito_user_pool.main.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  generate_secret = false
}

# ---------- API Gateway JWT Authorizer using Cognito ----------

resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id           = aws_apigatewayv2_api.http_api.id
  name             = "${var.project_prefix}-cognito-authorizer"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

# ---------- API Gateway Integrations & Routes ----------

# Integration: API Gateway -> Lambda (presigner)
resource "aws_apigatewayv2_integration" "presigner_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.presigner.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# Integration: API Gateway -> Lambda (uploader)
resource "aws_apigatewayv2_integration" "uploader_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.uploader.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# Route: POST /presign -> presigner integration (JWT protected)
resource "aws_apigatewayv2_route" "presigner_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /presign"
  target    = "integrations/${aws_apigatewayv2_integration.presigner_integration.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
}

# Route: POST /upload -> uploader integration (JWT protected)
resource "aws_apigatewayv2_route" "uploader_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /upload"
  target    = "integrations/${aws_apigatewayv2_integration.uploader_integration.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
}

# Stage: default stage with auto-deploy
resource "aws_apigatewayv2_stage" "default" {
  api_id = aws_apigatewayv2_api.http_api.id
  name   = "$default"

  auto_deploy = true
}

# Lambda permissions for API Gateway

resource "aws_lambda_permission" "apigw_invoke_presigner" {
  statement_id  = "AllowAPIGatewayInvokePresigner"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presigner.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_invoke_uploader" {
  statement_id  = "AllowAPIGatewayInvokeUploader"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uploader.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}
