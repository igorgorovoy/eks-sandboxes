terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
      # >= 6.0 потрібна для: compute_config (Auto Mode) та cpu_options.nested_virtualization.
      # Зафіксуй точну версію з CHANGELOG перед apply — для відтворюваності статті.
    }
  }
}
