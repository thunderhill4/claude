package ansible.security

import rego.v1

file_modules := {"copy", "template"}
command_modules := {"command", "shell"}

# ANS-SEC-001: Ansible file task without explicit file permissions
findings contains finding if {
    resource := input.resource
    resource.tool == "ansible"
    resource.type == "task"
    resource.attributes.module in file_modules
    not resource.attributes.mode
    finding := {
        "id": "ANS-SEC-001",
        "severity": "medium",
        "category": "configuration",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Ansible file task without explicit file permissions",
        "description": concat("", ["Ansible task '", resource.name, "' uses the '", resource.attributes.module, "' module without specifying a file mode, which may result in overly permissive file permissions."]),
        "remediation": "Add an explicit 'mode' parameter (e.g., mode: '0640') to all copy and template tasks to ensure correct file permissions.",
        "confidence": 0.85,
    }
}

# ANS-SEC-002: Ansible command task using sudo directly
findings contains finding if {
    resource := input.resource
    resource.tool == "ansible"
    resource.type == "task"
    resource.attributes.module in command_modules
    contains(resource.attributes.args, "sudo")
    finding := {
        "id": "ANS-SEC-002",
        "severity": "high",
        "category": "configuration",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Ansible command task using sudo directly",
        "description": concat("", ["Ansible task '", resource.name, "' uses sudo directly in a command/shell module. This bypasses Ansible's privilege escalation controls and may leave sensitive data in logs."]),
        "remediation": "Use Ansible's built-in become/become_user directives instead of calling sudo directly in command or shell tasks.",
        "confidence": 0.9,
    }
}
