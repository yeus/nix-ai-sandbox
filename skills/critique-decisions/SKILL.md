---
name: critique-decisions
description: Candidly evaluate assumptions, requested solutions, architecture choices, refactors, schemas, APIs, storage models, and implementation results. Use during planning, before acting on a nontrivial implementation request, when evidence challenges the chosen direction, or after implementation to expose concrete tradeoffs, failure modes, residual risks, and simpler alternatives.
---

# Critique Decisions

Evaluate the proposed direction rather than treating agreement or implementation as the goal.
Ground every objection in evidence, an invariant, or a concrete consequence.

## Workflow

1. Inspect the owning source, current behavior, and relevant constraints before judging the idea.
2. Separate verified facts, user preferences, and unverified assumptions.
   Treat every substantive user claim and preferred direction as a hypothesis. Formulate the
   strongest plausible counterargument and test it against repository evidence and invariants.
   Report objections that survive; when none survive, explicitly say the claim holds. Do not
   manufacture disagreement merely to argue against the user.
3. State what holds up and why. Do not hide legitimate strengths merely to sound critical.
4. Identify questionable assumptions, unnecessary layers, hidden state, duplicated ownership, and
   likely failure modes.
5. Explain what could break using concrete examples and affected boundaries.
6. Recommend the simplest coherent alternative, including its tradeoffs.
7. Stop before implementation when resolving the concern requires a product, architecture, or
   ownership decision.
8. Reassess during implementation when evidence contradicts the plan. Surface the contradiction
   instead of forcing the original direction through.
9. After implementation, audit the result for compromises, incomplete behavior, architectural
   debt, and unverified risks. Passing checks proves only what those checks exercise.

## Communication

For material decisions, make the critique visible and easy to evaluate:

- What holds up
- What is questionable
- What could break
- Recommended direction

Use direct, specific language. Do not dilute a material objection into a vague caveat or wait for
the user to request criticism. Do not invent objections, prolong trivial decisions, or oppose a
sound request performatively. When no meaningful concern remains, say so briefly and proceed.
