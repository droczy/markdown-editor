# Security review report template

Copy everything below the line to `reviews/YYYY-MM-<scope>.md` and fill in
every section. Write "None" rather than leaving a section out. Links are
relative to the `reviews/` folder.

---

# Security review YYYY-MM: <scope>

| | |
| --- | --- |
| Reviewed commit | `<full SHA>` (`<version or milestone>`) |
| Period | YYYY-MM-DD to YYYY-MM-DD |
| Reviewers | <names> |
| Approved by | <maintainer>, YYYY-MM-DD |
| Previous review | <link or "None"> |

## 1. Scope

- Components reviewed:
- Changes since the previous review:
- Out of scope:

## 2. Threat model

Changes to the [threat model](../threat-model.md): new assets, data flows,
trust boundaries and threats, or "None".

## 3. Automated evidence

| Check | Result | Evidence |
| --- | --- | --- |
| CI on the reviewed commit (all required checks) | | <run link> |
| Test coverage (lines) | | |
| Nightly fuzzing (duration, crashes) | | |
| Nightly mutation testing (missed mutants) | | |
| Dependency audit (`cargo deny check`) | | |
| macOS app verification | | |
| CodeQL alerts | | |
| Dependabot and secret scanning alerts | | |

## 4. Checklist

| ID | Result | Evidence and notes |
| --- | --- | --- |
| ENC-1 | pass / fail / n/a | |

All [checklist](../checklist.md) items, in order.

## 5. Attack attempts

| # | Boundary | Technique | Input | Result |
| --- | --- | --- | --- | --- |
| 1 | TB1 | | | |

## 6. Findings

### SR-YYYY-NNN: <title>

| | |
| --- | --- |
| Severity | Critical / High / Medium / Low |
| CVSS 4.0 | `CVSS:4.0/...` (score) |
| CWE | CWE-NNN: <name> |
| Component | |
| Status | Fixed in <PR, commit> / Accepted / Open (private advisory) |

- **Description:** What is wrong.
- **Impact:** What an attacker can achieve.
- **Fix:** What changed.
- **Regression test:** Name and location.

## 7. Accepted risks

| Risk | Justification | Review again |
| --- | --- | --- |

## 8. Summary

Overall assessment, open items with deadlines, and recommendations for the
next review.
