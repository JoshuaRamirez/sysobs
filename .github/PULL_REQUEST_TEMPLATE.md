## What this changes

<!-- One concern per PR. What was wrong, and why this is the right shape of fix. -->

## What you observed

<!-- This is an observability tool. Output before and after is the most
     useful thing in a PR description. Redact command lines and addresses. -->

## Checklist

- [ ] `./bin/sysobs selftest` passes
- [ ] New or changed parsing behaviour has a fixture, using a real string
- [ ] Schema changes went into the `SCHEMA` dict, not into three places
- [ ] Collectors that can fail record a degraded `source`, never a silent zero
- [ ] Docs updated if behaviour changed (README / CLAUDE.md / CHANGELOG.md)
