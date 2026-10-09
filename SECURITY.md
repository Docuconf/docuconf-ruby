# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/docuconf/docuconf-ruby/security/advisories/new)). Do not open a public issue, pull
request or discussion for a suspected vulnerability.

Include what you can of:

- the affected version of the `docuconf-anyway` gem, and of Ruby, anyway_config and Rails if they matter;
- what an attacker can do, and what they need first;
- steps or a minimal config class, contract or environment that reproduces it.

We work on the fix in a private security advisory, credit you in it unless you prefer otherwise, and publish the
advisory when a fixed release is out.

## Response targets

| | |
|---|---|
| Acknowledge the report | within 3 business days |
| First assessment (confirmed or not, severity) | as soon as we can reproduce it, and we keep you updated in the advisory |
| Fix | released as a patch to the supported version, then the advisory is published |

## Supported versions

The gem is released as described in [RELEASING.md](RELEASING.md). Security fixes go to the latest minor release, as
a new patch release:

| Artifact | Tag | Supported |
|---|---|---|
| Ruby SDK (`docuconf-anyway` on RubyGems.org) | `v*` | latest minor |

**During the beta, only the latest release is supported.** Upgrade to it to get a fix.

## Scope

In scope:

- the `docuconf-anyway` gem: its declaration API, boot validation, contract-first mode, the `docuconf export`
  command, the Railtie and its rake tasks; for example a secret's value that reaches an error, a log or an
  exported contract, or a file input that passes its checks but should not.

Out of scope: the example application under [`examples`](examples), vulnerabilities in dependencies that docuconf
does not make reachable (report those upstream, such as to anyway_config or Ruby's OpenSSL), and issues in a platform
or cluster that only arise from its own misconfiguration. The `docuconf` CLI, the Go SDK, the Helm chart and the CUE
meta-schema live in [docuconf-go](https://github.com/docuconf/docuconf-go) and follow its policy; other language
SDKs live in their own repositories.
