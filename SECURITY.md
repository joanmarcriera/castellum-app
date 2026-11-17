# Security policy

Castellum handles email credentials and message content, so security reports are taken seriously.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting: open the repository's
"Security" tab and choose "Report a vulnerability".

Please include: affected version or commit, macOS version, a description, and steps to reproduce.
Do not include real mail or credentials; use synthetic data.

## What to expect

- Acknowledgement within 7 days (this is a small project maintained in spare time).
- A fix or mitigation plan once the issue is confirmed, and credit in the release notes if you wish.
- Please allow a reasonable disclosure window (90 days by default) before going public.

## Supported versions

Castellum is pre-1.0. Only the latest release and `main` receive security fixes.

## Scope

In scope: the Rust core (`native/`), the macOS app (`apple/`), handling of credentials in the
Keychain, TLS and IMAP/SMTP handling, parsing and sanitising of untrusted mail content, and the
local-AI egress guard (requests to a model endpoint must stay on private addresses).

Out of scope: vulnerabilities in third-party mail servers, macOS itself, or a locally running
model server you configured.
