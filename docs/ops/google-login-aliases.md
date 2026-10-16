# Explicit Google login aliases

An operator may link a verified Google email to an existing Rupert account without allowing the entire email domain. The canonical account retains its email, password sign-in, tenant, role and permissions. Google sign-in through an alias requires an active account and workspace, and the canonical account's domain must still be allowed. Ordinary allowed-domain provisioning is unchanged.

After applying migration `20261016010135`, an authorized host operator can create a link in a production Rails console:

```ruby
account = User.find_by!(email: 'owner@company.example', active: true)
raise 'Workspace is inactive' unless account.tenant&.status == 'active'
raise 'Canonical domain is not allowed' unless OauthAllowedDomain.allowed?(account.email, tenant: account.tenant)
account.google_login_identities.create!(email: 'owner.personal@gmail.com')
```

Confirm ownership and authorization for both addresses before creating a link. A conflicting existing account email or alias is rejected. Runtime checks also reject later account-email collisions and cross-workspace sign-in. This host operation does not create an additional account or allow other Gmail users. There is no public or staff-facing linking endpoint.

The first successful login pins Google's verified `sub` to the alias under a row lock. Future logins require that same subject. A Google subject can belong to only one linked identity. Disabling the account or workspace, removing the canonical allowed domain, or deleting the alias prevents future sign-in through the alias. Revocation does not invalidate already-issued sessions; use the existing session/account controls when that is required. Never reset a pinned subject without verifying the replacement identity and obtaining fresh authorization.

Record the operator-approved link in the account's activity log. Do not record passwords, Google tokens or authorization codes. The alias grants the existing account's permissions, so treat linking as an account-access operation. Database backups must include the identity table.
