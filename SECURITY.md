# Security

## Reporting a vulnerability

Please use GitHub private vulnerability reporting: open the repository's Security tab and choose "Report a vulnerability". Do not open a public issue for security problems.

Bounce is maintained in spare time. Reports are read, but there is no guaranteed response time.

## Scope notes

- Sync runs between your own devices on the local network.
- After pairing, devices check a shared paired key. Transfers are plain HTTP on the local network and are not encrypted with TLS. Do not sync on networks you do not trust.
- Bounce makes no connections to the internet.
