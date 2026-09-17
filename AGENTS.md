# Calcar contributor rules

## Branches and review

- Never commit implementation directly to `main` or `develop`.
- Use a scoped working branch based on `develop`.
- Submit changes through a pull request targeting `develop`.
- Release pull requests target `main` from `develop`.
- Agents may push working branches and open pull requests when authorized.
- Agents must not merge pull requests or enable auto-merge.
- Do not force-push, delete protected branches, or change repository rules.
- Local branches do not enforce GitHub protection. Report missing remote rules.

## Scope and safety

- The PRD defines the product. Proposed architecture is not verified behavior.
- Do not implement remote execution or trust protocols before the P1 decisions
  and security review are complete.
- Keep the phone's trust authority separate from computer execution.
- Never put credentials, source content, prompts, or terminal output in telemetry.
- Preserve user work. Do not discard unrelated changes.
- Give parallel workers exclusive file scopes. Only one worker owns shared
  contracts at a time.

## Evidence

- Run the checks for changed components and exercise their actual entry points.
- Report what passed, what failed, and what was not tested.
- A placeholder, checklist, or successful compilation does not prove a feature.
- PRs must include scope, verification evidence, limitations, and dependencies.
