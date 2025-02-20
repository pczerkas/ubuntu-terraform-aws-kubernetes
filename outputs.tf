#####
# Output
#####

output "ssh_user" {
  description = "SSH user to download kubeconfig file"
  value       = "ubuntu"
}

output "public_ip" {
  description = "Cluster IP address"
  value       = aws_eip.master.public_ip
}

output "dns" {
  description = "Cluster DNS address"
  value       = aws_route53_record.master.fqdn
}

output "kubeconfig_dns" {
  description = "Path to the the kubeconfig file using DNS address"
  value       = "/home/ubuntu/kubeconfig"
}

output "kubeconfig_ip" {
  description = "Path to the kubeconfig file using IP address"
  value       = "/home/ubuntu/kubeconfig_ip"
}
