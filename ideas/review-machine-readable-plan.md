# Idea: machine-readable review plan output

## Summary

Extend the multi-pass pi review workflow with an optional machine-readable plan output in addition to the existing human-readable Markdown report.

Do not implement yet.

## Motivation

The current review flow now has:
1. aggregated review findings
2. a coherent change plan

A future enhancement could add a structured representation of the change plan so that follow-on tooling can:
- apply one step at a time
- track dependencies between steps
- separate behavior changes from refactors
- preserve suggested commit boundaries
- re-run or update only affected plan nodes
- support future automation without parsing prose

## Proposed format

Prefer **XML** as the first structured format.

Rationale:
- readable enough for humans during debugging
- hierarchical and good for nested plans
- explicit tags make dependency and grouping structure clear
- works well in prompts because the model can often preserve XML structure reliably
- pi already uses XML-style structured context in some places conceptually, so the shape is natural

## Possible shape

```xml
<review-plan scope="uncommitted" target="src/foo.rs">
  <strategy>
    <summary>Stabilize behavior first, then update tests, then perform naming and refactor cleanup.</summary>
  </strategy>

  <conflicts>
    <conflict id="c1">
      <issue>Security review suggests tighter validation at the boundary, while API review suggests reducing call-site boilerplate.</issue>
      <resolution>Introduce one validated constructor and keep boundary validation centralized.</resolution>
    </conflict>
  </conflicts>

  <steps>
    <step id="s1" kind="test" commitGroup="1">
      <title>Add regression tests for invalid state transitions</title>
      <files>
        <file>tests/foo_test.rs</file>
      </files>
      <dependsOn />
      <verification>
        <command>cargo test tests::foo</command>
      </verification>
    </step>

    <step id="s2" kind="behavior" commitGroup="2">
      <title>Fix invalid transition handling in src/foo.rs</title>
      <files>
        <file>src/foo.rs</file>
      </files>
      <dependsOn>
        <stepRef>s1</stepRef>
      </dependsOn>
      <verification>
        <command>cargo test tests::foo</command>
      </verification>
    </step>

    <step id="s3" kind="refactor" commitGroup="3">
      <title>Rename ambiguous state helper methods</title>
      <files>
        <file>src/foo.rs</file>
      </files>
      <dependsOn>
        <stepRef>s2</stepRef>
      </dependsOn>
    </step>
  </steps>

  <deferred>
    <item>
      <reason>Low value compared with current correctness work.</reason>
      <note>Postpone broad readability cleanups until after the functional fixes land.</note>
    </item>
  </deferred>
</review-plan>
```

## Candidate uses

- `/review` emits both Markdown and XML plan
- future `/review-show-plan` command
- future `/review-apply-next` command
- future plan diffing across revisions
- future selective re-review of one plan step or commit group

## Design constraints

- Human-readable Markdown remains the primary output.
- Structured output is additive, not a replacement.
- Prefer a minimal schema at first.
- Keep commit boundaries and dependency edges explicit.
- Distinguish behavior changes, tests, refactors, docs, and API changes.
- Allow deferred items and conflict resolution notes.

## Deferred

Not for immediate implementation.
