output "vpc_id" {
  value = aws_vpc.slice2.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "s3_vpc_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
