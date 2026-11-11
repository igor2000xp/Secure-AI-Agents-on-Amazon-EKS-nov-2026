variable "cluster_version" {
  description = "EKS cluster version."
  type        = string
  default     = "1.36"
}
variable "adot_addon_version" {
  description = "Version of the ADOT (AWS Distro for OpenTelemetry) EKS managed addon. Leave null to use the default version for the cluster's Kubernetes version."
  type        = string
  default     = null
}
