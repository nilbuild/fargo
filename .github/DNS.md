# Pointing streamif.com at GitHub Pages

Add these records in Cloudflare, then add a `CNAME` file to `site/` containing
`streamif.com` and push. Set the Cloudflare proxy to **DNS only** (grey cloud),
because the orange cloud breaks GitHub's certificate issuance.

| Type  | Name | Value                 |
|-------|------|-----------------------|
| A     | @    | 185.199.108.153       |
| A     | @    | 185.199.109.153       |
| A     | @    | 185.199.110.153       |
| A     | @    | 185.199.111.153       |
| CNAME | www  | nilbuild.github.io    |

Then in the repo: Settings, Pages, set the custom domain to `streamif.com` and
turn on Enforce HTTPS once the certificate is issued.

`SUFeedURL` in `Info.plist` already points at `https://streamif.com/appcast.xml`,
so this has to work before the first release ships.
