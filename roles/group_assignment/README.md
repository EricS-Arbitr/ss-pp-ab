# Group_Assignment Role

## Description
Assigns Active Directory users to specified security groups within the domain. The role processes a list of domain users and ensures they are members of their designated groups, typically used after domain controller promotion and user creation to establish proper group memberships.

## Variable Definition Location
Variables for this role should be defined in **group_vars/[domain].yml** where [domain] matches your AD domain inventory group name (e.g., site.yml, inet.yml)

## Required Variables

### In group_vars/[domain].yml

#### DomainUsers
List of users with their group assignments.

| Field | Required | Description |
|-------|----------|-------------|
| name | Yes | Username/samAccountName of the domain user |
| groups | Yes | List of AD groups the user should be a member of |

Note: The `DomainUsers` variable is shared with the create_users role and may contain additional fields (fullname, password) that are not used by this role.

## Optional Variables

None - this role uses only the required DomainUsers variable with name and groups fields.

## Automatically Available Variables

| Variable | Description |
|----------|-------------|
| domain_name | Domain name from group_vars/[domain].yml |

## Complete Example Configuration

### group_vars/site.yml
```yaml
domain_name: "site.com"

DomainUsers:
  - name: "simspace"
    fullname: "simspace"
    password: "Simspace1!Simspace1!"
    groups:
      - Domain Admins
  - name: "charity.bowen"
    fullname: "Charity Bowen"
    password: "Simspace1!Simspace1!"
    groups:
      - Domain Admins
  - name: "ahmed.ortega"
    fullname: "Ahmed Ortega"
    password: "Simspace1!Simspace1!"
    groups:
      - Domain Admins
  - name: "makenzie.melton"
    fullname: "Makenzie Melton"
    password: "Simspace1!Simspace1!"
    groups:
      - Domain Admins
      - Backup Operators
  - name: "joaquin.clayton"
    fullname: "Joaquin Clayton"
    password: "Simspace1!Simspace1!"
    groups:
      - Domain Users
      - Remote Desktop Users
```
Minimal Configuration
group_vars/inet.yml
```yaml
domain_name: "inet.com"

DomainUsers:
  - name: "admin.user"
    groups:
      - Domain Admins
  - name: "standard.user"
    groups:
      - Domain Users
