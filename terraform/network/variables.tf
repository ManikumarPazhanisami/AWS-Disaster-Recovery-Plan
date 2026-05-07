# =============================================================================
# network/variables.tf
# =============================================================================

variable "project_name"        { type = string }
variable "environment"         { type = string }
variable "vpc_cidr"            { type = string }
variable "primary_vpc_cidr"    { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "app_subnet_cidrs"    { type = list(string) }
variable "db_subnet_cidrs"     { type = list(string) }
variable "availability_zones"  { type = list(string) }
