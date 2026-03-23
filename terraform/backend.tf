# Terraform Backend Configuration
# Uses S3 for remote state storage

terraform {
  backend "s3" {
    bucket         = "agent-coder-terraform-state"
    key            = "oci/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "agent-coder-terraform-locks"
  }
}
