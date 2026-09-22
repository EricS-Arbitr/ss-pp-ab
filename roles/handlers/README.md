# Handlers Role

## Description
Provides a centralized collection of reusable handlers for common service management and system reboot operations. Other roles can include this as a dependency to access standardized handlers for restarting services and rebooting systems across both Windows and Linux platforms.

## Variable Definition Location
This role requires no variables - it provides handlers that respond to notifications from other roles.

## Required Variables
None - handlers use variables from the calling roles when needed.

## Available Handlers

### System Reboot Handlers

| Handler Name | Platform | Description | Timeout |
|--------------|----------|-------------|---------|
| Reboot Linux | Linux | Reboots Linux systems | 120 seconds |
| Reboot Windows | Windows | Reboots Windows systems | 600 seconds |

### Service Management Handlers

| Handler Name | Service | Platform | Description |
|--------------|---------|----------|-------------|
| Restart NetworkManager | NetworkManager | Linux | Restarts network management service |
| Restart squid | squid | Linux | Restarts Squid proxy service with enable |
| Restart apache2 | apache2 | Linux | Restarts Apache web server with enable |
| Restart Splunk Service | splunk | Linux | Restarts Splunk service |

### Splunk-Specific Handlers

| Handler Name | Description |
|--------------|-------------|
| Initialize Splunk | Enables boot-start, accepts license, sets admin password |
| Start Splunk After Installing and Initializing | Starts Splunk service after initial setup |

## Usage

### Including as a Dependency

Other roles include handlers as a dependency in their `meta/main.yml`:

```yaml
---
dependencies:
  - role: handlers
```
Notifying Handlers
Roles can then notify these handlers in their tasks:
```yaml
- name: Configure network interface
  template:
    src: interface.j2
    dest: /etc/network/interfaces
  notify: Restart NetworkManager

- name: Install Windows updates
  win_updates:
    category_names:
      - SecurityUpdates
  notify: Reboot Windows
