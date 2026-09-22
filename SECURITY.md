# Security Policy

## Supported Versions

Only the latest released version of Fargo gets security fixes. Fargo updates
itself through Sparkle, so most users already run the latest version.

## Reporting a Vulnerability

Please **do not** open a public issue for a security problem.

Report it privately with [GitHub Security Advisories](https://github.com/nilbuild/fargo/security/advisories/new)
for this repository. If you cannot use that, send an email to
kamran@insightmediagroup.io.

Include:
- What the vulnerability is and what it affects
- Steps to reproduce it
- The version you found it in (Fargo → About)

You should get a first reply within a few days.

## Scope

In scope:
- The Fargo macOS app (`macos/Fargo`)
- The RTMP client (`Services/RTMP`)
- OAuth flows for YouTube and Twitch (`Services/YouTube`)
- The release and update pipeline (Sparkle appcast, code signing)

Out of scope:
- Problems in third-party streaming platforms (YouTube, Twitch, Kick,
  Facebook). Report those to the platform.
- Social engineering, physical access, and denial-of-service reports
