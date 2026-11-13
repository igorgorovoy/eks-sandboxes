variable "cluster_name" {
  type    = string
  default = "agents-sandbox"
}

variable "kubernetes_version" {
  description = "Nitro Sandboxes in EKS Auto Mode require >= 1.36"
  type        = string
  default     = "1.36"

  validation {
    condition     = tonumber(split(".", var.kubernetes_version)[1]) >= 36
    error_message = "Nitro Sandboxes in EKS Auto Mode require Kubernetes >= 1.36."
  }
}

variable "sandbox_instance_type" {
  description = "The same instance type for all three pools (nitro / gvisor / microvm) — for a fair benchmark"
  type        = string
  default     = "m8i.xlarge"

  validation {
    condition     = can(regex("^(c8i|m8i|r8i)(-flex)?\\.", var.sandbox_instance_type))
    error_message = "Nested virtualization (the microVM pool) is only supported on 8th-gen Intel: c8i, m8i, r8i (and -flex). Graviton is not supported."
  }
}
