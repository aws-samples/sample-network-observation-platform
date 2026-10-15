output "injector_function_name" {
  description = "Scheduled demo data-injector Lambda."
  value       = aws_lambda_function.injector.function_name
}

output "injector_schedule_rule" {
  description = "EventBridge rule driving the injector."
  value       = aws_cloudwatch_event_rule.injector.name
}
