variable "project_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "secure-file-sharing"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "s3_bucket_name" {
  description = "S3 bucket name for file storage (must be globally unique)"
  type        = string
  default     = "secure-file-sharing-neurops-uploads"
}
