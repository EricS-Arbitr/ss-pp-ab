# Splunk-Forwarder Role

## Description
Installs and configures Splunk Universal Forwarder on Windows and Linux systems to collect and forward log data to a central Splunk server. The role downloads the forwarder through the corporate proxy, performs silent installation, and deploys configuration files for data collection and forwarding.

## Variable Definition Location
Variables for this role are defined in:
- **group_vars/splunk-forwarder.yml** splunk user, password, port, and installer nexus locations
- **host_vars/[hostname].yml** or **group_vars/[domain].yml** for Splunk server targeting

## Required Variables

### In group_vars/splunk-forwarder.yml

| Variable | Required | Description |
|----------|----------|-------------|
| splunk_forwarder_installer | Yes | URL to the Splunk forwarder MSI installer |
| splunk_forwarder_installer_deb | Yes | URL to the Debian Splunk forwarder installer |
| splunk_forwarder_admin | Yes | admin username to install splunk forwarder |
| splunk_forwarder_admin_password | Yes | Password to admin user |
| splunk_forwarder_port | Yes | Port to connect to Splunk on |
| splunk_forwarder_win_dir | Yes | Installation directory for Splunk forwarder on Windows |


### In group_vars/all.yml

| Variable | Required | Description |
|----------|----------|-------------|
| inet_proxy_addr | Yes | IP address of the proxy server |
| inet_proxy_port | Yes | Port number for the proxy server |
| splunk_forwarder_admin | Yes | admin username to install splunk forwarder |
| splunk_forwarder_admin_password | Yes | Password to admin user |

### In host_vars or group_vars

| Variable | Required | Description |
|----------|----------|-------------|
| splunk_server_ip | Yes* | IP address of the Splunk indexer (*role only runs when defined) |
| splunk_forwarder_port | Yes | Port to connect to Splunk on |
| splunk_user | Yes | User to install forwarder on linux machines |
| splunk_Password | Yes | Password for user on linux forwarder machines |

## Optional Variables

None - this role uses only the required variables listed above.


## Complete Example Configuration

### group_vars/splunk-forwarder.yml
```yaml
splunk_forwarder_admin: "admin"
splunk_forwarder_admin_password: "simspace1"
splunk_forwarder_installer_deb: "https://nexus.dev.ng.simspace.lan/repository/ng_raw/installers/Splunk/Forwarder/Debian/splunkfwd.deb"
splunk_forwarder_port: "9997"
splunk_forwarder_win_dir: "C:\\Program Files\\SplunkUniversalForwarder"
splunk_forwarder_installer: "https://nexus.dev.ng.simspace.lan/repository/ng_raw/installers/Splunk/Forwarder/8.2.6/splunkforwarder-8.2.6.msi"
```
group_vars/all.yml
```yaml
# Proxy configuration
inet_proxy_addr: "10.255.240.1"
inet_proxy_port: "3128"
splunk_forwarder_admin: "admin"
splunk_forwarder_admin_password: "simspace1"
```
group_vars/site.yml
```yaml
splunk_server_ip: "172.16.3.20"
splunk_forwarder_port: "9997"
splunk_user: "admin"
splunk_password: "simspace1"
splunk_forwarder_win_dir: "C:\\Program Files\\SplunkUniversalForwarder"
```
