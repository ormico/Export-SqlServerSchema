---
name: review-feedback
description: Triage and address PR code review comments — assess validity, plan fixes, implement, and report decisions to the user.
disable-model-invocation: true
argument-hint: "[pr-number] (auto-detects from current branch if omitted)"
allowed-tools:
  - Bash(git *)
  - Bash(gh *)
  - Bash(docker *)
  - Bash(docker-compose *)
  - Bash(pwsh *)
  - Bash(cp *)
  - Bash(mkdir *)
  - Bash(ls *)
  - Bash(cat *)
  - Edit
  - Write
  - Read
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
---

# Address PR Code Review Feedback

Determine the PR number:
1. If `$ARGUMENTS` contains a number, use that as the PR number
2. Otherwise, auto-detect from the current branch:
   ```bash
   gh pr list --head $(git branch --show-current) --json number,title,url
   ```
3. If no PR is found, ask the user for the PR number

## Phase 1: Gather Comments

Fetch all review comments on the PR:

```bash
gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/comments --jq '.[] | {id, path, line, body, user: .user.login, created_at}'
```

Also check for top-level PR review summaries:

```bash
gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/reviews --jq '.[] | {user: .user.login, state, body}'
```

## Phase 2: Triage — Assess Each Comment

For each comment, read the relevant code and assess:

1. **Is it valid?** Does the comment identify a real bug, quality issue, or improvement?
2. **What's the priority?** High (bug/correctness), Medium (quality/testing), Low (style/nice-to-have), Trivial (cosmetic)
3. **Should we fix it?** Not all valid comments need action — some may be out of scope, overly speculative, or conflict with project conventions.

### Present a Summary Table to the User

Before implementing anything, show the user a table like:

| # | Comment (summary) | Valid? | Priority | Action |
|---|-------------------|--------|----------|--------|
| 1 | Description...    | Yes    | High     | Fix — real bug |
| 2 | Description...    | Yes    | Low      | Skip — cosmetic only |
| 3 | Description...    | No     | —        | Skip — misunderstands design |

For any comment you recommend skipping, explain why. The user makes the final call.

**Ask the user** which comments to address before proceeding. Do not start implementing without user approval on the triage.

## Phase 3: Plan Fixes

For approved comments, plan the implementation:

- Group related comments that can be fixed together
- Identify which files need changes
- Consider whether fixes need new or updated tests
- Check if fixes could break existing tests or functionality

Present the plan briefly — this doesn't need `EnterPlanMode` unless the fixes are architecturally complex.

## Phase 4: Implement Fixes

For each approved fix:

1. Make the code change
2. Add or update tests if the comment was about correctness or missing coverage
3. Verify the fix addresses the specific concern raised

Follow all project conventions (see `copilot-instructions.md`).

## Phase 5: Run Tests

Run all relevant tests to confirm fixes don't break anything:

```bash
# Run feature-specific tests
pwsh -NoProfile -File tests/<relevant-test>.ps1

# Run integration tests if changes affect export/import behavior
pwsh -NoProfile -File tests/run-integration-test.ps1
```

If integration tests are needed and Docker isn't running:

```bash
docker ps --filter "name=sqlserver" --format "{{.Names}} {{.Status}}"
# Start only if not running:
cd tests && docker-compose up -d
```

Copy `tests/.env` from main repo if missing in worktree:
```bash
cp "D:\Export-SqlServerSchema\tests\.env" ./tests/.env
```

## Phase 6: Report to User

Summarize what was done:

- **Fixed**: List each comment that was addressed and what changed
- **Skipped (approved)**: Comments the user agreed to skip, with rationale
- **Skipped (user override)**: Comments the user decided not to fix despite recommendation
- **New issues found**: Any problems discovered during fixes that weren't in the original review

If tests pass, the changes are ready to commit.

## Phase 7: Commit

Create a commit describing the review fixes:

```bash
git add <specific-files>
git commit -m "fix: address PR review feedback (#$ARGUMENTS)

- Fixed: <brief list of what was fixed>
- Skipped: <brief note on what was intentionally not changed>"
```

Do NOT push unless the user explicitly asks. Do NOT add Co-Authored-By or Claude attribution.

## Important Reminders

- **The user decides** what gets fixed — always present triage before implementing
- **Explain your reasoning** for skip recommendations — the user needs to defend decisions to reviewers
- **Don't over-fix** — address what was raised, don't refactor nearby code
- **Update CHANGELOG.md** only if fixes are substantive (bug fixes, behavior changes), not for cosmetic cleanup
- **If a comment requires a design change**, flag it to the user — it may warrant a separate issue rather than a PR fix
