resource "aws_s3_bucket" "data_engineering" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "data_engineering" {
  bucket = aws_s3_bucket.data_engineering.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_engineering" {
  bucket = aws_s3_bucket.data_engineering.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_engineering" {
  bucket = aws_s3_bucket.data_engineering.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
