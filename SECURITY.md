# Security Policy

## Supported Versions

Only the latest released version of Streamif gets security fixes. Streamif updates
itself through Sparkle, so most users already run the latest version.

## Reporting a Vulnerability

Please **do not** open a public issue for a security problem.

Report it privately with [GitHub Security Advisories](https://github.com/nilbuild/streamif/security/advisories/new)
for this repository. If you cannot use that, send an email to
kamranahmed.se@gmail.com.

Include:
- What the vulnerability is and what it affects
- Steps to reproduce it
- The version you found it in (Streamif → About)

You should get a first reply within a few days.

## Scope

In scope:
- The Streamif macOS app (`macos/Streamif`)
- The RTMP client (`Services/RTMP`)
- OAuth flows for YouTube and Twitch (`Services/YouTube`)
- The release and update pipeline (Sparkle appcast, code signing)

Out of scope:
- Problems in third-party streaming platforms (YouTube, Twitch, Kick,
  Facebook). Report those to the platform.
- Social engineering, physical access, and denial-of-service reports
