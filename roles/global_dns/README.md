# DNS Role

## Description
Configures  global DNS records on the simulated internet "is-inet" VM using an unbound includes file. 

This role supports the following record types: A, AAAA, CNAME, MX, NS, PTR


## Variable Definition Location
Variables for this role should be defined in **group_vars/all.yml** 

## Required Variables

#### global_dns_records
List of DNS records to create.

| Field | Required | Description |
|-------|----------|-------------|
| name | No | Record name |
| type | Yes | Record type (A, AAAA, CNAME, PTR, NS, MX) |
| value | Yes | Record value (IP address, hostname, or text) |
| zone | Yes | DNS zone for the record |
| ttl | No | Time to live in seconds |
|  priority | No | DNS record priority |
| state | No | Record state (present or absent), defaults to present |

## Example Configuration

### group_vars/all.yml
```yaml
global_dns_records:
  - name: "www"
    type: "A"
    value: "200.200.200.1"
    zone: "site.com"

  - name: "mail"
    type: "A"
    value: "200.200.200.1"
    zone: "site.com"

  - name: "mail"
    type: "A"
    value: "52.96.223.2"
    zone: "outlook.com"

  - type: "MX"
    priority: 10
    value: "mail.outlook.com"
    zone: "outlook.com"
```
