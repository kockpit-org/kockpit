locals {
  healthcheck_port_number = var.service_healthcheck_port == "traffic-port" ? var.service_port : tonumber(var.service_healthcheck_port)

  ingress_source_security_groups = concat(var.in_security_groups, var.enable_load_balancer ? [var.lb_security_group_id] : [])

  environment_variables = [
    for k, v in var.environment_variables : {
      name  = k
      value = v
    }
  ]

  secrets = [
    for k, v in var.secrets : {
      name      = k
      valueFrom = v
    }
  ]
}
