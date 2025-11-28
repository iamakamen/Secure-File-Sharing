output "s3_bucket_name" {
  value       = aws_s3_bucket.files.bucket
  description = "Name of the S3 bucket used for file storage"
}

output "files_table_name" {
  value       = aws_dynamodb_table.files.name
  description = "DynamoDB table name for file metadata"
}

output "audit_table_name" {
  value       = aws_dynamodb_table.audit.name
  description = "DynamoDB table name for audit logs"
}


output "api_base_url" {
  value       = aws_apigatewayv2_api.http_api.api_endpoint
  description = "Base URL for the HTTP API"
}


output "cognito_user_pool_id" {
  value       = aws_cognito_user_pool.main.id
  description = "Cognito User Pool ID"
}

output "cognito_user_pool_client_id" {
  value       = aws_cognito_user_pool_client.main.id
  description = "Cognito App Client ID"
}
