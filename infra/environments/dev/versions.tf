terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "danny-data-engineering"
    key          = "terraform-state/dev/slice0.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
  }
}
