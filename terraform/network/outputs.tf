# =============================================================================
# network/outputs.tf
# =============================================================================

output "vpc_id"               { value = aws_vpc.dr.id }
output "public_subnet_ids"    { value = aws_subnet.public[*].id }
output "app_subnet_ids"       { value = aws_subnet.app[*].id }
output "db_subnet_ids"        { value = aws_subnet.db[*].id }
output "db_subnet_group_name" { value = aws_db_subnet_group.aurora_dr.name }
output "nat_gateway_ids"      { value = aws_nat_gateway.dr[*].id }
output "sg_alb_id"            { value = aws_security_group.alb.id }
output "sg_nginx_id"          { value = aws_security_group.nginx.id }
output "sg_app_id"            { value = aws_security_group.app.id }
output "sg_aurora_id"         { value = aws_security_group.aurora.id }
output "sg_lambda_id"         { value = aws_security_group.lambda.id }
