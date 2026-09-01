variable "aws_region" {
  description = "AWS region for Slice 2 資源"
  type        = string
  default     = "ap-northeast-1"
}

variable "private_subnet_cidrs" {
  description = "私有子網 CIDR，key 為可用區代碼後綴。至少需要 2 個 AZ：RDS DB Subnet Group 要求橫跨至少 2 個 AZ，MSK Provisioned 的 broker 數也必須是供應 AZ 數的倍數（§3.3(a) 已定 2 broker）。此帳號在 ap-northeast-1 實際可用的 AZ 為 a/c/d（b 不可用，實測得知），故選 a/c"
  type        = map(string)
  default = {
    a = "10.20.1.0/24"
    c = "10.20.2.0/24"
  }
}
