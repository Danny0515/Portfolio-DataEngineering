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

output "logs_vpc_endpoint_id" {
  value = aws_vpc_endpoint.logs.id
}

output "trade_db_endpoint" {
  value = aws_db_instance.trade.address
}

output "trade_generator_function_name" {
  value = aws_lambda_function.trade_generator.function_name
}

output "msk_cluster_arn" {
  value = aws_msk_cluster.trade.arn
}

output "msk_bootstrap_brokers_tls" {
  value = aws_msk_cluster.trade.bootstrap_brokers_tls
}

output "glue_schema_registry_name" {
  value = aws_glue_registry.trade_events.registry_name
}

output "glue_schema_registry_arn" {
  value = aws_glue_registry.trade_events.arn
}

output "trade_events_schema_arn" {
  value = aws_glue_schema.trade_events.arn
}

output "msk_connect_plugin_bucket_name" {
  value = aws_s3_bucket.msk_connect_plugins.id
}

output "debezium_postgres_plugin_arn" {
  value = aws_mskconnect_custom_plugin.debezium_postgres.arn
}

output "debezium_postgres_plugin_latest_revision" {
  value = aws_mskconnect_custom_plugin.debezium_postgres.latest_revision
}

output "glue_schema_registry_converter_plugin_arn" {
  value = aws_mskconnect_custom_plugin.glue_schema_registry_converter.arn
}

output "glue_schema_registry_converter_plugin_latest_revision" {
  value = aws_mskconnect_custom_plugin.glue_schema_registry_converter.latest_revision
}

output "msk_connector_arn" {
  value = aws_mskconnect_connector.debezium_postgres.arn
}

output "msk_connector_name" {
  value = aws_mskconnect_connector.debezium_postgres.name
}

output "msk_connect_worker_log_group_name" {
  value = aws_cloudwatch_log_group.msk_connect_debezium.name
}

output "debezium_combined_plugin_arn" {
  value = aws_mskconnect_custom_plugin.debezium_combined.arn
}

output "debezium_combined_plugin_latest_revision" {
  value = aws_mskconnect_custom_plugin.debezium_combined.latest_revision
}

output "msk_connect_execution_role_arn" {
  value = aws_iam_role.msk_connect_debezium.arn
}
