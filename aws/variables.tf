variable "prefix" { default = "" }
variable "ssh_key_name" { default = "" }
variable "vault_cluster_size" { default = 3 }
variable "ami_id" { default = "" }
variable "ami_filter_owners" {
  description = "When bash install method, use a filter to lookup an image owner and name. Common combinations are 206029621532 and amzn2-ami-hvm* for Amazon Linux 2 HVM, and 099720109477 and ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-* for Ubuntu 18.04"
  type        = list(string)
  default     = ["099720109477"]
}
variable "ami_filter_name" {
  description = "When bash install method, use a filter to lookup an image owner and name. Common combinations are 206029621532 and amzn2-ami-hvm* for Amazon Linux 2 HVM, and 099720109477 and ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-* for Ubuntu 18.04"
  type        = list(string)
  default     = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
}
variable "vpc_id" { default = "" }
variable "subnet_ids" { default = "" }
# This is not implimented yet
#variable "vault_ent_license" { default = "" }
variable "vault_version" {
  default = "1.5.0"
}
variable "vault_download_url" { default = "" }
variable "cluster_tag_key" { default = "consul-servers" }
variable "cluster_tag_value" { default = "auto-join" }
variable "vault_path" { default = "" }
variable "vault_user" { default = "" }
variable "ca_path" { default = "" }
variable "cert_file_path" { default = "" }
variable "key_file_path" { default = "" }
variable "server" { default = true }
variable "client" { default = false }
variable "config_dir" { default = "" }
variable "data_dir" { default = "" }
variable "systemd_stdout" { default = "" }
variable "systemd_stderr" { default = "" }
variable "bin_dir" { default = "" }
variable "datacenter" { default = "" }
variable "trailing_logs" { default = "" }
variable "environment" { default = "" }
variable "recursor" { default = "" }
variable "tags" {
  description = "Map of extra tags to attach to items which accept them"
  type        = map(string)
  default     = {}
}
variable "force_bucket_destroy" {
  description = "Boolean to force destruction of s3 buckets"
  default     = false
  type        = bool
}
variable "enable_deletion_protection" { default = true }
variable "subnet_second_octet" { default = "0" }
