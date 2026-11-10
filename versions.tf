terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
      # >= 6.0 is required for: compute_config (Auto Mode) and cpu_options.nested_virtualization.
      # Pin the exact version from the CHANGELOG before apply — for the article's reproducibility.
    }
  }
}
