# =============================================================================
# compute/outputs.tf
# =============================================================================

output "app_launch_template_id"   { value = aws_launch_template.app.id }
output "nginx_launch_template_id" { value = aws_launch_template.nginx.id }
output "nginx_eip_allocation_id"  { value = aws_eip.nginx.allocation_id }
output "nginx_eip_public_ip"      { value = aws_eip.nginx.public_ip }
output "s3_crr_role_arn"          { value = aws_iam_role.s3_crr.arn }
output "s3_dr_bucket_names"       { value = aws_s3_bucket.dr[*].bucket }
output "sqs_queue_urls"           { value = [aws_sqs_queue.dr.url, aws_sqs_queue.dr_dlq.url] }
output "health_check_id"          { value = aws_route53_health_check.primary.id }
