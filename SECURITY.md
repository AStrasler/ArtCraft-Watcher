# Security Policy

## Deployment boundary

This repository is safe to publish only when deployment-specific values remain outside source control.

Do not commit:

- Supabase project references or live function URLs
- service-role keys
- access tokens
- Vault secrets
- cron authentication secrets
- private notification endpoints
- local device names or filesystem paths
- personal email addresses or account identifiers
- operator-specific installed-version state

## Runtime authentication

The crawler accepts requests only when the caller provides the private cron secret in the `x-artcraft-cron` header.

The secret is generated inside Postgres, stored in Supabase Vault, and represented in the public schema only by a SHA-256 hash.

## Reporting a vulnerability

Please use GitHub's private security reporting features when available. Do not open a public issue containing a live deployment URL, credential, token, secret, or other sensitive runtime information.
