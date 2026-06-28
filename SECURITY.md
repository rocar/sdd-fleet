# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via one of:

1. **GitHub Private Vulnerability Reporting** (preferred) — the *Report a
   vulnerability* button under the repository's **Security** tab. Enable it at
   *Settings → Code security → Private vulnerability reporting*.
2. **Email** — raycar@gmail.com with the subject line `sdd-fleet security`.

Please include a description, affected version (`.claude-plugin/plugin.json`),
and reproduction steps. Expect an acknowledgement within a few days.

## Scope

sdd-fleet is a Claude Code plugin: shell hooks, JavaScript dynamic-workflow
scripts, and agent/skill definitions. Of particular interest:

- Hook scripts that can be coerced into running unintended commands.
- Workflow scripts (`workflows/*.js`) that mishandle untrusted input.
- Any path that lets a feature spec or bug report escape the `.sdd/` sandbox.

## Supported versions

Only the latest released version (the `version` in
`.claude-plugin/plugin.json`) receives security fixes.
