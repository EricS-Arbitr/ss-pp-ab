# Common Role

## Description
Configures fundamental system settings including hostname and network interfaces for both Windows and Linux systems. The role automatically detects the OS platform and applies appropriate configuration methods - NetworkManager for Linux and DSC (Desired State Configuration) for Windows. It also handles DNS settings, disables legacy networking services on Linux, and ensures proper hostname resolution.

## Variable Definition Location
Variables for this role should be defined in **host_vars/[hostname].yml**

## Required Variables

### In host_vars/[hostname].yml

#### network_interfaces
List of network interfaces to configure on the system.

| Field | Required | Description |
|-------|----------|-------------|
| name | Yes | Interface name (eth0/eth1 for Linux, Ethernet0/Ethernet1 for Windows) |
| ipv4.type | Yes (Linux only) | Interface type - always "ethernet" for Linux |
| ipv4.address | Yes | IP address for the interface |
| ipv4.netmask | Yes | Subnet mask in dotted decimal format |
| ipv4.gateway | No | Default gateway (use empty string "" for no gateway) |
| dns | No | List of DNS servers for this interface |

## Optional Variables

### In group_vars/site.yml

| Variable | Required | Description |
|----------|----------|-------------|
| domain_name | No | Domain name for DNS search suffix (only applied if defined) |

### Automatically Available Variables

| Variable | Description |
|----------|-------------|
| inventory_hostname | Hostname from Ansible inventory - automatically sets system hostname |
| ansible_host | Management IP address from host_vars |

## Complete Example Configuration

### host_vars/site-www.yml (Linux)
```yaml
ansible_host: 10.10.1.2

network_interfaces:
  - name: "eth0"
    ipv4:
      type: "ethernet"
      address: "10.10.1.2"
      netmask: "255.255.0.0"
      
  - name: "eth1"
    ipv4:
      type: "ethernet"
      address: "172.16.1.2"
      netmask: "255.255.255.0"
      gateway: "172.16.1.1"
    dns:
      - "172.16.2.7"
      - "8.8.8.8"
```
host_vars/acc-win10-1.yml (Windows)
```yaml
ansible_host: 10.10.6.111

network_interfaces:
  - name: "Ethernet0"
    ipv4:
      address: "10.10.6.111"
      netmask: "255.255.0.0"
      gateway: ""
      
  - name: "Ethernet1"
    ipv4:
      address: "172.16.6.111"
      netmask: "255.255.255.0"
      gateway: "172.16.6.1"
    dns:
      - "172.16.2.7"
```
host_vars/site-dc.yml (Windows)
```yaml
ansible_host: 10.10.2.7

network_interfaces:
  - name: "Ethernet0"
    ipv4:
      address: "10.10.2.7"
      netmask: "255.255.0.0"
      gateway: ""
      
  - name: "Ethernet1"
    ipv4:
      address: "172.16.2.7"
      netmask: "255.255.255.0"
      gateway: "172.16.2.1"
    dns:
      - "127.0.0.1"
      - "8.8.8.8"
```
host_vars/site-proxy.yml (Linux)
```yaml
ansible_host: 10.10.2.6

network_interfaces:
  - name: "eth0"
    ipv4:
      type: "ethernet"
      address: "10.10.2.6"
      netmask: "255.255.0.0"
      
  - name: "eth1"
    ipv4:
      type: "ethernet"
      address: "172.16.2.6"
      netmask: "255.255.255.0"
      gateway: "172.16.2.1"
    dns:
      - "8.8.8.8"
      - "172.16.2.7"
```
Minimal Configuration
host_vars/site-mail.yml (Linux)
```yaml
ansible_host: 10.10.2.8

network_interfaces:
  - name: "eth0"
    ipv4:
      type: "ethernet"
      address: "10.10.2.8"
      netmask: "255.255.0.0"
```
host_vars/acc-win10-2.yml (Windows)
```yaml
ansible_host: 10.10.6.112

network_interfaces:
  - name: "Ethernet0"
    ipv4:
      address: "10.10.6.112"
      netmask: "255.255.0.0"
```
