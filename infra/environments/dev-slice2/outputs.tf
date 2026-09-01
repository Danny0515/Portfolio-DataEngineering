output "vpc_id" {
  value = aws_vpc.slice2.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "s3_vpc_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "glue_vpc_endpoint_id" {
  value = aws_vpc_endpoint.glue.id
}

output "internal_security_group_id" {
  value = aws_security_group.slice2_internal.id
}
