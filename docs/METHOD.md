# How this work was delivered

The work ran as a small delegated team. One side builds; the other reviews.
Building and reviewing in the same pass produces checks that agree with the
code, because the same assumptions wrote both, so they were kept apart.

Each task was built, run against a real runtime, and its output captured before
a word was written about it. Every figure in the report comes from a log in
`docs/evidence/`, written by `scripts/run-with-evidence.sh`, which records the
command, the timestamp and the full output, and pipes the result through
`scripts/redact.sh` so redaction is part of the capture path rather than a step
someone remembers.

Review runs under seven written briefs in `.claude/agents/`. Each reviewer is an
automated role with a written brief; the names are names.

| | | |
|---|---|---|
| **Faris** | the knight | attacks tests until they prove they can fail |
| **Adel** | the just | traces every claim to evidence and re-derives it |
| **Amin** | the trusted | scans content and history by signature |
| **Hasib** | the reckoner | owns cloud resource lifecycle, creation to teardown |
| **Ghareeb** | the stranger | fresh clone, clean state, stripped environment |
| **Rawi** | the narrator | writes only from evidence, and has no shell |
| **Fahim** | the perceptive | questions the author on decisions and trade-offs |

The tool scopes are part of the design. Rawi has no shell, so every number it
publishes comes from a log something else produced. Faris may break a check to
prove it can fail but does not repair it, because the right repair is sometimes
to delete the check. Fahim is read-only.

Six practices carried most of the weight:

- **Every assertion has been seen to fail for the right reason.** Passing checks
  are mutated — the value changed, the dependency removed, the fix reverted —
  and a check that stays green under mutation is reported rather than trusted.
- **Every published figure is traced to a captured log and re-derived** from the
  raw output rather than read off a summary line, with the arithmetic in the
  surrounding prose recomputed too.
- **Every measurement is bounded** against something physical or documented —
  link capacity, a cgroup limit, a published service limit — and named for the
  layer it describes.
- **Secrets are scanned by content signature across the full history**, not by
  filename, and any string resembling a placeholder is verified against the real
  value rather than judged by how it reads.
- **Reproduction is checked from a fresh clone** with a stripped environment and
  no generated state, installing from the lockfile and running the documented
  entry points exactly as written.
- **Cloud resources are torn down, and the teardown is verified per resource
  class against the provider's own listings** rather than against the tool that
  created them.

Anything irreversible — creating cloud resources, publishing, rewriting history
— passes through a human decision gate before it happens.

The briefs in `.claude/agents/` are written to be read on their own, and stand
as the methodology in full.
