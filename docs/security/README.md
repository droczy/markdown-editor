# Security reviews

Security is the top priority of this project. This folder defines how
security is reviewed, so that every review follows the same steps and
produces comparable results.

| Document | Purpose |
| --- | --- |
| [Threat model](threat-model.md) | Assets, attackers, trust boundaries, threats and mitigations |
| [Checklist](checklist.md) | Requirements checked in every full review, based on OWASP ASVS 5.0 |
| [Report template](report-template.md) | Structure of every full review report |

Completed reports are published in `docs/security/reviews/`:

- [2026-11: phase 2](reviews/2026-11-phase-2.md): Rust core, FFI and the
  macOS app skeleton.

## When reviews happen

- **Short review:** in every pull request that touches a security-relevant
  area. The pull request template contains the questions.
- **Full review:** at the end of every roadmap phase and before every
  release, covering the whole project.

Security-relevant areas are:

- Markdown parsing, HTML generation and sanitization.
- The preview.
- File access.
- The boundary between the Rust core and the apps.
- Entitlements, signing and build settings.
- Dependencies.
- CI workflows and repository settings.

## Short review

The *Security* section of the pull request answers:

1. Which untrusted input or trust boundary does the change affect?
2. Which threats from the [threat model](threat-model.md) apply?
3. Which mitigations and tests address them? Attack tests are required for
   new input paths.
4. Which dependencies are added or updated? Give the reason, license,
   maintenance status and known advisories.
5. What residual risk remains?

Changes that affect none of the areas above state "Not security-relevant".

## Full review

Every full review follows these eight steps in order.

1. **Scope:** Name the reviewed commit and version, the components, the
   changes since the last review and anything out of scope.
2. **Threat model:** Update the [threat model](threat-model.md) for new
   components, data flows and trust boundaries, using STRIDE per boundary.
3. **Automated evidence:** Collect the results for the reviewed commit:
   - CI: tests, coverage, short fuzzing, dependency audit and the app
     verification.
   - The latest nightly fuzzing and mutation testing.
   - CodeQL.
   - Dependabot and secret scanning alerts.
4. **Checklist:** Assess every item of the [checklist](checklist.md) as
   *pass*, *fail* or *not applicable*, with evidence.
5. **Attack attempts:** Attack every trust boundary manually and with
   scripts. Typical attacks are injection payloads, resource exhaustion,
   malformed files and confusing input. Record each input and its result.
6. **Findings:** Record every exploitable weakness as a finding with an ID,
   a CWE, a CVSS 4.0 vector and score, and a severity. A failed checklist
   item without an attack path, such as a missing CI timeout, is hardening.
   It is fixed and documented in the checklist results instead.
7. **Fixes:** Fix every finding with a regression test within its
   deadline, or accept it as a residual risk with a justification.
8. **Report:** Write the report from the
   [template](report-template.md). The maintainer approves it before it
   is published in `reviews/`.

### Finding IDs

`SR-YYYY-NNN`, numbered sequentially per year across all reviews, for
example `SR-2026-001`. IDs are never reused.

### Severity and deadlines

The severity follows the qualitative rating of CVSS 4.0.

| Severity | CVSS 4.0 score | Deadline |
| --- | --- | --- |
| Critical | 9.0 - 10.0 | Fix immediately, before any other work |
| High | 7.0 - 8.9 | Fix immediately |
| Medium | 4.0 - 6.9 | Fix before the next beta release |
| Low | 0.1 - 3.9 | Fix before the next stable release |

## Disclosure

- Open findings are tracked only in private GitHub security advisories,
  never in public issues, pull requests or commit messages.
- Fixes are published as regular pull requests. Their descriptions explain
  the effect and the fix, not how to exploit the weakness.
- Once a finding is fixed, it is published in the review report, in the
  *Security* section of the [changelog](../../CHANGELOG.md) and in the
  release notes. High and critical findings that affected a published
  release also get a public security advisory, and a CVE where applicable.
- Weaknesses in dependencies are mitigated in this project. Public
  descriptions focus on the effect and the mitigation.
- Accepted residual risks are published with a justification, unless they
  are easy to exploit.

To report a vulnerability, see the [security policy](../../SECURITY.md).
