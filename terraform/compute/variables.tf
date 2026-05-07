# =============================================================================
# compute/variables.tf
# =============================================================================

variable "project_name"        { type = string }
variable "environment"         { type = string }
variable "primary_region"      { type = string }
variable "dr_region"           { type = string }
variable "app_subnet_ids"      { type = list(string) }
variable "public_subnet_ids"   { type = list(string) }
variable "sg_app_id"           { type = string }
variable "sg_nginx_id"         { type = string }
variable "sg_lambda_id"        { type = string }
variable "app_instance_type"   { type = string }
variable "nginx_instance_type" { type = string }
variable "app_instance_count"  { type = number }
variable "app_ami_id"          { type = string; default = "" }
variable "nginx_ami_id"        { type = string; default = "" }
variable "key_pair_name"       { type = string }
variable "s3_bucket_names"     { type = list(string) }
variable "hosted_zone_id"      { type = string; default = "" }
variable "api_domain"          { type = string }
variable "db_cname"            { type = string }
variable "dr_db_endpoint"      { type = string; default = "" }
variable "sns_alarm_arn"       { type = string; default = "" }
