resource "aws_security_group" "ecs" {
  description = "ingress to the app task"

  vpc_id = var.vpc.id
  name   = "ecs-${var.application}-${var.env}"

  // HTTP. Skipped when nothing may reach the task (no load balancer and no
  // in_security_groups): an ingress rule without any source is not valid.
  dynamic "ingress" {
    for_each = length(local.ingress_source_security_groups) > 0 ? [1] : []
    content {
      protocol        = "tcp"
      from_port       = var.service_port
      to_port         = var.service_port
      security_groups = local.ingress_source_security_groups
    }
  }

  // Separate health check port (e.g. a management/actuator port distinct from service_port)
  dynamic "ingress" {
    for_each = length(local.ingress_source_security_groups) > 0 && local.healthcheck_port_number != var.service_port ? [1] : []
    content {
      protocol        = "tcp"
      from_port       = local.healthcheck_port_number
      to_port         = local.healthcheck_port_number
      security_groups = local.ingress_source_security_groups
    }
  }

  // Output
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
