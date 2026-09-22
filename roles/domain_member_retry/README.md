# Domain_Member_Retry Role

## Description
Joins Windows systems to an Active Directory domain with automatic retry logic. If the initial domain join fails, the role automatically reboots the system and retries the operation. The computer name is set from the Ansible inventory hostname.

## Variable Definition Location
Variables for this role should be defined in **group_vars/[domain].yml** where [domain] matches your AD domain inventory group name (e.g., site.yml, inet.yml)

## Required Variables

### In group_vars/[domain].yml

| Variable | Required | Description |
|----------|----------|-------------|
| domain_name | Yes | Active Directory domain to join |
| domain_admin | Yes | Domain administrator username |
| domain_admin_password | Yes | Domain administrator password |

### Automatically Available Variables

| Variable | Description |
|----------|-------------|
| inventory_hostname | Computer name from Ansible inventory |

## Complete Example Configuration

### group_vars/site.yml
```yaml
domain_name: "site.com"
domain_admin: "simspace"
domain_admin_password: "Simspace1!Simspace1!"
```
group_vars/inet.yml
```yaml
domain_name: "inet.com"
domain_admin: "admin"
domain_admin_password: "InetPass123!"
```
hosts
```yaml
[site]
site-file
site-mail
site-www

[inet]
inet-web
inet-db

[members]
site-file
site-mail
site-www
inet-web
inet-db
