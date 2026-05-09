variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "dr_region" {
  description = "The DR region where the secret will be replicated"
  type        = string
}

variable "secret_name" {
  description = "Name of the secret to create"
  type        = string
  default     = "app-credentials"
}
