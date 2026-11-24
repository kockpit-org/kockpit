resource "aws_security_group" "ecs" {
  description = "ingress to the app task"

  vpc_id = var.vpc.id
  name   = "ecs-${var.application}-${var.env}"

  // Inbound rules, written in attribute form (ingress = [...]) on purpose:
  // with dynamic "ingress" blocks, an empty set means "not managed" and
  // Terraform leaves the old rules in place (kockpit-auditstream kept its
  // ALB rules after enable_load_balancer = false). An explicit list makes
  // Terraform own all inbound rules, so an empty list removes them.
  // Attribute form needs every field set.
  ingress = length(local.ingress_source_security_groups) == 0 ? [] : concat(
    [{
      description      = ""
      protocol         = "tcp"
      from_port        = var.service_port
      to_port          = var.service_port
      security_groups  = local.ingress_source_security_groups
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      self             = false
    }],
    // Separate health check port (e.g. a management/actuator port distinct from service_port)
    local.healthcheck_port_number == var.service_port ? [] : [{
      description      = ""
      protocol         = "tcp"
      from_port        = local.healthcheck_port_number
      to_port          = local.healthcheck_port_number
      security_groups  = local.ingress_source_security_groups
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      self             = false
    }]
  )

  // Output
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
