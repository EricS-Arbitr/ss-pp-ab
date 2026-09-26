# DNS Role

## Description
Configures DNS zones and records on the Active Directory Domain Controller. The role automatically creates forward and reverse lookup zones based on the records defined, manages internal DNS records, and configures WPAD for proxy auto-discovery if a proxy server is defined.

This role supports the following record types: A, AAAA, CNAME, DHCID, NS, PTR, SRV, TXT


## Variable Definition Location
Variables for this role should be defined in **group_vars/[domain].yml** where [domain] matches your AD domain inventory group name (e.g., site.yml, inet.yml)

## Required Variables

### In group_vars/[domain].yml

#### internal_dns_records
List of DNS records to create.

| Field | Required | Description |
|-------|----------|-------------|
| name | Yes | Record name |
| type | Yes | Record type (A, AAAA, CNAME, PTR, NS, TXT, SRV) |
| value | Yes | Record value (IP address, hostname, or text) |
| zone | Yes | DNS zone for the record |
| ttl | No | Time to live in seconds |
| state | No | Record state (present or absent), defaults to present |

## Optional Variables

### In group_vars/[domain].yml

| Variable | Required | Description |
|----------|----------|-------------|
| proxy_server | No | IP address of proxy server for automatic WPAD record creation |
| domain_name | Yes | Primary domain name for WPAD record zone |

## Complete Example Configuration

### group_vars/site.yml
```yaml
domain_name: "site.com"
proxy_server: "172.16.2.6"

internal_dns_records:
  # A Records
  - name: "www"
    type: "A"
    value: "172.16.1.2"
    zone: "site.com"
    
  - name: "mail"
    type: "A"
    value: "172.16.2.8"
    zone: "site.com"
    
  - name: "file"
    type: "A"
    value: "172.16.2.3"
    zone: "site.com"
    
  # CNAME Records
  - name: "test-www"
    type: "CNAME"
    value: "www.site.com"
    zone: "site.com"
    
  - name: "webmail"
    type: "CNAME"
    value: "mail.site.com"
    zone: "site.com"
    
  # PTR Records (Reverse DNS)
  - name: "2.1.16.172.in-addr.arpa"
    type: "PTR"
    value: "www.site.com"
    zone: "1.16.172.in-addr.arpa"
    
  - name: "8.2.16.172.in-addr.arpa"
    type: "PTR"
    value: "mail.site.com"
    zone: "2.16.172.in-addr.arpa"
    
  - name: "3.2.16.172.in-addr.arpa"
    type: "PTR"
    value: "file.site.com"
    zone: "2.16.172.in-addr.arpa"
```
Minimal Configuration
group_vars/site.yml
```yaml
domain_name: "site.com"

internal_dns_records:
  - name: "server1"
    type: "A"
    value: "172.16.1.10"
    zone: "site.com"
```
Reverse DNS Example
group_vars/site.yml
```yaml
internal_dns_records:
  # Forward lookup
  - name: "dc"
    type: "A"
    value: "172.16.2.7"
    zone: "site.com"
    
  # Reverse lookup for 172.16.2.0/24 network
  - name: "7.2.16.172.in-addr.arpa"
    type: "PTR"
    value: "dc.site.com"
    zone: "2.16.172.in-addr.arpa"
```
Zone Creation
The role automatically creates DNS zones based on unique zones found in the records:

Forward zones: Standard domain zones (e.g., site.com)
Reverse zones: Zones ending in .in-addr.arpa or .ip6.arpa

Example Zone Detection
```yaml
internal_dns_records:
  # This will create "site.com" zone if it doesn't exist
  - name: "www"
    type: "A"
    value: "172.16.1.2"
    zone: "site.com"
    
  # This will create "dev.site.com" zone if it doesn't exist  
  - name: "app"
    type: "A"
    value: "172.16.10.1"
    zone: "dev.site.com"
    
  # This will create "1.16.172.in-addr.arpa" reverse zone
  - name: "2.1.16.172.in-addr.arpa"
    type: "PTR"
    value: "www.site.com"
    zone: "1.16.172.in-addr.arpa"
```
WPAD Configuration
If proxy_server is defined, the role automatically:

Creates a WPAD A record pointing to the proxy server
Disables DNS Global Query Block List to allow WPAD queries

```yaml
# Defining this variable automatically creates wpad.site.com -> 172.16.2.6
proxy_server: "172.16.2.6"
