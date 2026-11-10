variable "cluster_name" {
  type    = string
  default = "agents-sandbox"
}

variable "kubernetes_version" {
  description = "Nitro Sandboxes в Auto Mode потребують >= 1.36"
  type        = string
  default     = "1.36"

  validation {
    condition     = tonumber(split(".", var.kubernetes_version)[1]) >= 36
    error_message = "Nitro Sandboxes в EKS Auto Mode потребують Kubernetes >= 1.36."
  }
}

variable "sandbox_instance_type" {
  description = "Той самий тип для всіх трьох пулів (nitro / gvisor / microvm) — для чесного бенчмарку"
  type        = string
  default     = "m8i.xlarge"

  validation {
    condition     = can(regex("^(c8i|m8i|r8i)(-flex)?\\.", var.sandbox_instance_type))
    error_message = "nested virtualization (microVM-пул) підтримується лише на Intel 8-го покоління: c8i, m8i, r8i (та -flex). Graviton не підтримується."
  }
}
