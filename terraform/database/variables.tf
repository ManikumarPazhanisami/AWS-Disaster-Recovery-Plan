# =============================================================================
# database/variables.tf
# =============================================================================

variable "project_name"               { type = string }
variable "environment"                { type = string }
variable "dr_region"                  { type = string }
variable "primary_cluster_identifier" { type = string }
variable "dr_cluster_identifier"      { type = string }
variable "aurora_engine_version"      { type = string }
variable "aurora_min_capacity"        { type = number }
variable "aurora_max_capacity"        { type = number }
variable "db_subnet_group_name"       { type = string }
variable "aurora_security_group_id"   { type = string }
variable "sns_alarm_arn"              { type = string; default = "" }
variable "replication_lag_threshold"  { type = number; default = 5000 }

# =============================================================================
# database/outputs.tf
# =============================================================================
