resource "aws_route53_zone" "main" {
  name = "eef1c20b.tk"
}

resource "aws_route53_record" "vault" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "vault.${aws_route53_zone.main.name}"
  type    = "A"

  alias {
    name                   = module.primary_cluster.vault_load_balancer
    zone_id                = module.primary_cluster.vault_load_balancer_zone
    evaluate_target_health = true
  }
}

module "certbot" {
  source = "git::https://github.com/kingsoftgames/certbot-lambda.git//terraform"
  lambda_name = "certbot"
  hosted_zone_id = aws_route53_zone.main.zone_id
  domains = ["vault.${aws_route53_zone.main.name}"]
  emails = ["cmatteson@hashicorp.com"]
  upload_s3 = {
    bucket = module.primary_cluster.setup_bucket
    prefix = "foo"
    region = "us-east-1"
  }
}
