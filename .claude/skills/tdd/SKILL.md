---
name: tdd
description: >-
  Drives a change test-first: one failing test, the smallest code that passes
  it, then refactor. Invoke with /tdd when starting a feature or fixing a bug
  that should have had a test.
argument-hint: "[what to build or fix]"
disable-model-invocation: true
---

Work in one-behaviour cycles. Never write production code without a failing
test demanding it.

## Before the first cycle

State the behaviour in one sentence, and list the cases you expect to cover —
the happy path, the boundaries, and the errors. Get agreement on that list
before writing anything. It is the cheapest moment to notice a wrong
assumption.

Find the existing tests for the nearest comparable code and match their
structure, naming, and assertion style. `AGENTS.md` says existing patterns
outrank every other rule, and that applies to tests first.

## The cycle

**Red.** Write exactly one test for the next unproven case. Run it. Watch it
fail, and check it fails *for the reason you expect* — a test that passes
immediately, or fails on a typo, is proving nothing.

**Green.** Write the least code that makes it pass. Not the design you have
in mind; the least code. Run the test. Run the rest of the suite too, so you
know you didn't break something.

**Refactor.** Now improve the shape, with the tests as your safety net. Run
them again. This step is not optional — it is where the design comes from.

Then stop and report the cycle before starting the next one. One behaviour
per cycle, and never two failing tests at once.

## Test quality

- Assert **behaviour**, not implementation. A test that restates the code
  breaks on every refactor and catches nothing.
- One reason to fail per test. When it goes red, the name should tell you
  what broke.
- Name the case, not the method: what goes in, what comes out, under what
  condition.
- No logic in a test — no loops or conditionals deciding what to assert.
  Table-driven cases are fine; branching is not.
- Cover the error paths. Untested failure handling is usually broken failure
  handling.

## When to stop

Stop when every case on the list is green and the code has no branch a test
doesn't reach. Aim for 80%+ coverage on new code, and say plainly what you
left uncovered and why. Never write a test purely to move the number.

## Bugs

A bug means a test was missing. Reproduce it as a failing test *first*, in
the smallest form you can, then fix it. That test is the thing that stops it
coming back — the fix on its own is not.
