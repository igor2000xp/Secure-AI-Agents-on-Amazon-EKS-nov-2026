terraform {
  required_version = ">= 1.3"

  # Providers are pinned to EXACT versions (not ranges) so `terraform init`
  # resolves identically on every machine and every day. Loose ranges
  # (e.g. ">= 2.20.0") let init drift to a newer — possibly major — release
  # whenever someone re-resolves, which is what caused the provider sync issue.
  # The committed .terraform.lock.hcl backs this up; bump these deliberately.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.52.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.0"
    }
    # Pulled in transitively by the EKS / blueprints-addons modules. Pinned so
    # init is fully deterministic (otherwise these float).
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.3.0"
    }
  }

  # ##  Used for end-to-end testing on project; update to suit your needs
  # backend "s3" {
  #   bucket = "terraform-ssp-github-actions-state"
  #   region = "us-west-2"
  #   key    = "e2e/karpenter/terraform.tfstate"
  # }
}