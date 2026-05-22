# Wordpress-PV Role

## Description
Deploys a vulnerable WordPress container environment for cyber range activities using Docker Compose. The role configures Docker to use the internal Nexus registry, sets up proxy settings, and launches a WordPress container with MariaDB database, including intentionally vulnerable plugins for security training scenarios.

## Variable Definition Location
Variables for this role are defined in **group_vars/all.yml** for proxy configuration

## Required Variables

### In group_vars/all.yml

| Variable | Required | Description |
|----------|----------|-------------|
| inet_proxy_addr | Yes | IP address of the proxy server for Docker |
| inet_proxy_port | Yes | Port number for the proxy server |

## Optional Variables

None - the role uses predefined container configurations.

## Dependencies

This role requires the **docker** role to be executed first to install Docker and Docker Compose.

## Container Configuration

### WordPress Container
- **Image**: nexus-docker.dev.ng.simspace.lan/simspace/wordpress-pv:latest
- **Ports**: 
  - 80 → 8080 (HTTP)
  - 443 → 8443 (HTTPS)
- **Vulnerable Plugins**:
  - wp-statistics
  - 3dprint-lite
- **PHP Memory**: 512M
- **Database**: MariaDB backend

### MariaDB Container
- **Image**: nexus-docker.dev.ng.simspace.lan/mariadb:10.6.4-focal
- **Database Name**: wp
- **Database User**: wp
- **Database Password**: simspace1
- **Root Password**: simspace1

## Complete Example Configuration

### group_vars/all.yml
```yaml
# Proxy configuration
inet_proxy_addr: "10.255.240.1"
inet_proxy_port: "3128"
```
