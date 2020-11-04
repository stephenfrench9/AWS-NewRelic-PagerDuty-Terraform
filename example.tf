locals {
  thresholds = {
    "app-0" = 0
    "app-1" = 10
    "app-2" = 10
  }
}

################# AWS ####################
provider "aws" {
  region  = "us-west-2"
}

###### Security Group
data "http" "my_public_ip" {
  url = "https://ifconfig.co/json"
  request_headers = {
    Accept = "application/json"
  }
//https://stackoverflow.com/questions/46763287/i-want-to-identify-the-public-ip-of-the-terraform-execution-environment-and-add
}

locals {
  ifconfig_co_json = jsondecode(data.http.my_public_ip.body)
}

resource "aws_security_group" "stephens_sg" {
  name = "stephen-from-terraform"
  ingress {
    from_port = 22 //int
    to_port = 22 //int
    protocol = "tcp" //string
    cidr_blocks = ["${local.ifconfig_co_json.ip}/32"] //list of strings
  }

  egress {
    from_port = 0 //int
    to_port = 0 //int
    protocol = "-1" //string
    cidr_blocks = ["0.0.0.0/0"] //list of strings
  }

  tags = {
    Name = "tag-from-terraform-on-sg"
  }
}

##### Key
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "stephens-new-shiny-public-key"
  public_key = tls_private_key.example.public_key_openssh
  tags = {
    Name = "test-instance-june2020"
  }
}

resource "local_file" "foo" {
    content     = tls_private_key.example.private_key_pem
    filename = "${path.module}/public.pem"
    file_permission = "400"
}

##### ec2
resource "aws_instance" "web" {
  for_each = local.thresholds
  ami = "ami-0528a5175983e7f28"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.generated_key.key_name
  vpc_security_group_ids = [aws_security_group.stephens_sg.id]
  tags = {
    Name = each.key
    newrelic = "infrastructure"
  }
}

output "install" {
  value = "ssh -i \"public.pem\" ec2-user@${aws_instance.web[sort(keys(local.thresholds))[0]].public_dns}  'bash -s' < installterraform.sh && ssh -i \"public.pem\" ec2-user@${aws_instance.web[sort(keys(local.thresholds))[1]].public_dns}  'bash -s' < installterraform.sh && ssh -i \"public.pem\" ec2-user@${aws_instance.web[sort(keys(local.thresholds))[2]].public_dns}  'bash -s' < installterraform.sh"
}

################# PagerDuty ####################
provider "pagerduty" {
// export PAGERDUTY_TOKEN="ddddddddd"
}

resource "pagerduty_user" "hankaarron" {
  name  = "Hank Aarron"
  email = "uw.tutoring30@gmail.com"
  role = "user" //base role, somehow related to allowed team roles maybe
//  "admin"
//  "limited_user"
//  "observer"
//  "owner"
//  "read_only_user"
//  "read_only_limited_user"
//  "restricted_access"
//  "user"
}

resource "pagerduty_escalation_policy" "foo" {
  name      = "Engineering Escalation Policy"
  num_loops = 2

  rule {
    escalation_delay_in_minutes = 10

    target {
      type = "user"
      id   = pagerduty_user.hankaarron.id
    }
  }
}

resource "pagerduty_service" "apps" {
  for_each = local.thresholds
  name                    = "PDService-${each.key}"
  auto_resolve_timeout    = 14400
  acknowledgement_timeout = 600
  escalation_policy       = pagerduty_escalation_policy.foo.id
  alert_creation          = "create_alerts_and_incidents"
}

data "pagerduty_vendor" "newrelic" {
  name = "New Relic"
}

resource "pagerduty_service_integration" "PDService-hook" {
  for_each = local.thresholds
  name    = "New Relic Integration"
  service = pagerduty_service.apps[each.key].id
  vendor  = data.pagerduty_vendor.newrelic.id
}


################# New Relic ####################
provider "newrelic" {
//  export NEW_RELIC_ACCOUNT_ID = <a number, not a string>
//  export NEW_RELIC_API_KEY = ""
//  account_id = <a number, not a string>
//  api_key = <a string>
  region = "US"                        # Valid regions are US and EU
}

resource "newrelic_alert_policy" "PDPolicy" {
  for_each = local.thresholds
  name = "PDPolicy_${each.key}"
}

resource "newrelic_infra_alert_condition" "high_cpu-0" {
  for_each = local.thresholds
  policy_id = newrelic_alert_policy.PDPolicy[each.key].id

  name       = "High CPU"
  type       = "infra_metric"
  event      = "SystemSample"
  select     = "cpuPercent"
  comparison = "above"
  where = "(hostname LIKE '${aws_instance.web[each.key].private_dns}')"

  critical {
    duration      = 10
    value         = local.thresholds[each.key]
    time_function = "any"
  }
}

resource "newrelic_alert_channel" "to-PDService" {
  for_each = local.thresholds
  name = "to-PDService_${each.key}"
  type = "pagerduty"

  config {
    service_key = pagerduty_service_integration.PDService-hook[each.key].integration_key //this key is to a PDService
  } // in the PD abstraction
}

# Link the channel to the policy
resource "newrelic_alert_policy_channel" "NRPolicy-link-NRChannel" {
  for_each = local.thresholds
  policy_id  = newrelic_alert_policy.PDPolicy[each.key].id
  channel_ids = [
    newrelic_alert_channel.to-PDService[each.key].id
  ]
}
