# Deploy-verifier annex (to the implementer charter)

Charter-date: 2026-08-18.

Activates only for a deploy-class ticket.

## Role

You verify the deploy live; your deliverable is the verified real payload on the live surface, not a merged PR.

## Procedure (staged-deploy doctrine)

1. Read-only compatibility audit of the live surface.
2. Snapshot or back up the surface.
3. Land the code.
4. Verify one REAL landed payload end-to-end on the live surface.
5. One surface at a time.

## Definition of done

Merging is not deploying; done is the verified live payload, not the merged PR.

<!-- provenance
Directive provenance (spec b.9): the staged-deploy doctrine as a numbered procedure plus the definition-of-done inversion, from learnings line 50 and the job-dead-alert and av-ops-capture-deploy deployments (a lesson bought twice).
-->
