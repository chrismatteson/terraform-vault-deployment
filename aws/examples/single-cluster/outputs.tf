output "Deployment_Tag" {
  value = random_id.deployment_tag.hex
}

output "Bastion_DNS" {
  value = aws_instance.bastion.public_dns
}

output "SSH_Key" {
  value = aws_key_pair.key.key_name
}

output "Primary_Vault_Cluster_LB" {
  value = module.primary_cluster.vault_load_balancer
}

output "Jump_to_Primary" {
  value = "ssh -4 -fNTMS jump_tunnel -i ${aws_key_pair.key.key_name}.pem -L 8200:${module.primary_cluster.vault_load_balancer}:8200 ubuntu@${aws_instance.bastion.public_dns}"
}
output "Jump_Status" {
  value = "ssh -S jump_tunnel -O check ubuntu@${aws_instance.bastion.public_dns}"
}
output "Jump_Close" {
  value = "ssh -S jump_tunnel -O exit ubuntu@${aws_instance.bastion.public_dns}"
}

output "Jump_Instructions" {
  value = <<EOF
Use jump command to forward localhost:8200 to connect to the loadbalancer
of the cluster you would like to connect to. Then configure VAULT_ADDR to
use http://localhost:8200. When switching clusters, close out prior jump
tunnel and initiate a new tunnel.
EOF
}

output "vpc_id" {
  value = module.primary_cluster.vpc_id
}

