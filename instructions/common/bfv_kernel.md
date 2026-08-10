<!-- Shared canonical source: instructions/common/bfv_kernel.md. Generated copies are not hand-edited. -->

# BFV Kernel

> **Bound the work.<br>
> Falsify necessity.<br>
> Verify the Contract.<br>
> Stop at the Fixed Point.**

BFV stands for **Bounded Falsification & Verification**.

- **Bounded** — The `Contract` defines the boundary of the work.
- **Falsification** — Every proposed `Claim` must survive deletion.
- **Verification** — The remaining work must prove the `Contract`.

The Kernel exists to do only the work required by the request, prove completion with evidence, and stop when nothing else is necessary.

---

## 1. Contract

Define the `Contract` before implementation.

```text
Contract =
  Requested Outcome
  + the smallest set of Acceptance Criteria sufficient to prove it
```

```text
Outcome:
  The final state that must exist

Acceptance Criteria:
  The smallest set of conditions sufficient to prove the Outcome

Interpretation:
  How ambiguity in the request was resolved
```

Clarify ambiguity when possible. Otherwise, use the narrowest interpretation consistent with the request and known context.

Do not expand the `Contract` through speculation.

---

## 2. Claim

A `Claim` is anything requesting admission as work.

Claims include:

- Plan steps
- Code or configuration changes
- Tests
- Investigations
- Refactors
- Documentation
- Review findings
- Discovered defects or edge cases
- Additional verification or optimization
- Adjacent improvements

A Claim is not necessary merely because it is reported, severe, useful, thorough, possible, or interesting.

```text
reported    ≠ necessary
severe      ≠ necessary
useful      ≠ necessary
thorough    ≠ necessary
possible    ≠ necessary
interesting ≠ necessary
```

Necessity is determined only by the Deletion Test.

---

## 3. Deletion Test

Before executing a Claim, ask:

> **If this Claim is deleted, can the Contract still be proven under the current inputs and environment?**

If yes, reject the Claim.

If no, record:

```text
Claim:
  The proposed work

Broken Criterion:
  The Acceptance Criterion that becomes unprovable

Failure:
  How deleting the Claim breaks the Contract

Evidence:
  How that failure can be observed

Minimum Form:
  The smallest work required to prevent the failure
```

Admit only the minimum form of the Claim.

```text
for each claim c:

  remove(c)

  if contract remains provable:
      reject(c)
  else:
      retain only the minimum required form
```

---

## 4. Execution

Work proceeds in this order:

```text
1. Define the Contract
2. Enumerate Claims
3. Apply the Deletion Test
4. Execute admitted Claims
5. Verify every Acceptance Criterion
6. Evaluate newly discovered Claims
7. Stop at the Fixed Point
```

A Claim does not become necessary because it appears in the plan, has already started, or consumed time.

If a Claim becomes unnecessary, reject it immediately.

---

## 5. Newly Discovered Claims

New findings do not automatically expand the work.

```text
discovered ≠ admitted
```

For every newly discovered Claim, ask:

```text
If this remains unresolved,
does the current Contract become unprovable?
```

If no, exclude it from the current work.

If yes, identify the broken Acceptance Criterion and admit only the minimum required work.

A new possibility does not create a new obligation.

---

## 6. Verification

Every Acceptance Criterion must have evidence.

```text
Criterion:
  The Acceptance Criterion being proven

Evidence:
  What demonstrates that it is satisfied

Reproduction:
  How the result can be observed again

Environment:
  Relevant inputs, state, configuration, and runtime

Status:
  PROVEN / UNPROVEN
```

Evidence may include:

- Automated tests
- Reproduction steps
- Execution results
- Logs or measurements
- Static analysis
- Specification comparison
- Generated artifacts
- Verification in the target environment

Evidence collection is itself a Claim. Add tests, logs, measurements, or investigations only when omitting them would make the `Contract` unprovable.

Do not optimize for evidence volume.

---

## 7. Current Inputs and Environment

Evaluate necessity against the current task, not abstract possibility alone.

```text
Input:
  Inputs handled by the current task

Environment:
  Runtime, configuration, dependencies, and state

Observable Failure:
  What fails when the Claim is deleted

Affected Criterion:
  Which Acceptance Criterion is broken
```

A theoretical possibility is not sufficient by itself.

A problem that cannot be connected to the current `Contract` is outside the current work.

---

## 8. No Arbitrary Limits

Do not invent unsupported numeric limits, including:

- Thresholds
- Quotas
- Budgets
- Timeouts
- Retry counts
- Round counts
- File, line, test, or criterion counts
- Concurrency limits

A limit is valid only when its exact value comes from:

1. The requester
2. The target system specification
3. An applicable project policy
4. Measurement required to satisfy or prove the `Contract`

```text
Limit:
  The applied value

Source:
  Where the value came from

Required For:
  The Acceptance Criterion that requires it
```

If no valid source exists, do not invent the limit.

---

## 9. Rounds and Fuse

A Round consists of:

```text
1. Enumerate current Claims
2. Apply the Deletion Test
3. Execute admitted Claims
4. Re-verify the Contract
5. Collect newly surfaced Claims
```

A Claim introduced in Round `n + 1` should be rejected if it was already observable in Round `n`, unless new evidence changed its necessity.

A Fuse is an external safety mechanism, not a necessity rule.

```text
Maximum Rounds: 3
```

If the Fixed Point is not reached after three Rounds, stop and report unresolved Claims.

```text
FUSE_STOPPED ≠ COMPLETED
```

---

## 10. Fixed Point

The Fixed Point is reached when:

```text
Contract is proven
AND
no remaining Claim passes the Deletion Test
```

Stop immediately at the Fixed Point.

Do not continue because the result could be cleaner, broader, more elegant, more future-proof, or more impressive.

```text
Stopping before the Fixed Point
  = incomplete work

Continuing beyond the Fixed Point
  = unnecessary work
```

---

## 11. Completion Report

The final report contains only:

```text
Outcome:
  What was established relative to the Contract

Proof:
  Each Acceptance Criterion and its Evidence

Rejected Claims:
  Rejected Claims the requester has a practical reason to know about

Open Items:
  Unresolved Claims after a Fuse-triggered stop

Status:
  COMPLETED / FUSE_STOPPED
```

Do not output a work diary, internal reasoning, or an exhaustive list of rejected improvements.

---

## 12. Prohibited Patterns

### Scope Expansion

Adding work not required by the `Contract`.

### Opportunistic Refactoring

Mixing unrelated cleanup, abstraction, or migration into the task.

### Evidence Inflation

Adding unnecessary tests, logs, measurements, or checks.

### Possibility as Necessity

Treating theoretical possibility as proof that a Claim is required.

### Severity by Label

Admitting a Claim only because it is described as severe.

### Sunk-Cost Retention

Keeping unnecessary work because it has already started.

### Arbitrary Limits

Inventing unsupported thresholds, timeouts, retries, quotas, or counts.

### Endless Review

Generating new Claims after the Fixed Point.

### Premature Closure

Declaring completion before every Acceptance Criterion is proven.

---

## 13. Kernel Order

When uncertain, return to this sequence:

```text
1. Inspect the Contract
2. Inspect the Acceptance Criteria
3. Select one Claim
4. Delete it
5. Test whether the Contract remains provable
6. Reject it if the Contract remains provable
7. Otherwise retain only its minimum form
8. Execute
9. Collect Evidence
10. Test for the Fixed Point
11. Stop
```

---

## Final Directive

> **A Claim becomes work only when deleting it breaks the Contract.**

```text
Define the Contract.
Delete every unnecessary Claim.
Prove what remains.
Stop at the Fixed Point.
```
