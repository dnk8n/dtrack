aws_region         = "af-south-1"
instance_type      = "t3.medium"
vpc_cidr           = "10.0.0.0/16"
subnets_cidr       = ["10.0.1.0/24"]
availability_zones = ["af-south-1a"]

# Global Secrets
cloudflare_api_token = "dummy"
github_token         = "dummy"
domain               = "dummy"

environments = {
  staging = {
    subdomain        = "dtrack-staging"
    deploy_key_pvt   = "keys/staging/deploy/id"
    deploy_key_pub   = "keys/staging/deploy/id.pub"
    instance_key_pvt = "keys/staging/instance/id"
    instance_key_pub = "keys/staging/instance/id.pub"
    override         = "staging-demo"

    # Environment Secrets
    traefik_basicauth           = "dummy"
    acme_email                  = "dummy"
    postgres_password_superuser = "dummy"
    postgres_password_app       = "dummy"
    postgres_password_app_admin = "dummy"
    postgres_user_app_power     = "Dummy.User@example.com"
    azure_tenant_id             = "dummy"
    azure_client_id             = "dummy"
  }
  prod = {
    subdomain        = "dtrack"
    deploy_key_pvt   = "keys/prod/deploy/id"
    deploy_key_pub   = "keys/prod/deploy/id.pub"
    instance_key_pvt = "keys/prod/instance/id"
    instance_key_pub = "keys/prod/instance/id.pub"
    override         = "prod"

    # Environment Secrets
    traefik_basicauth           = "dummy"
    acme_email                  = "dummy"
    postgres_password_superuser = "dummy"
    postgres_password_app       = "dummy"
    postgres_password_app_admin = "dummy"
    postgres_user_app_power     = "Dummy.User@example.com"
    azure_tenant_id             = "dummy"
    azure_client_id             = "dummy"
  }
}
