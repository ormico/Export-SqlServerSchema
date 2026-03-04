---
name: work-issue
description: Work on a GitHub issue end-to-end in a worktree with TDD, integration testing, self-review, and documentation updates.
disable-model-invocation: true
argument-hint: "<issue-number>"
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
  - EnterPlanMode
  - EnterWorktree
  - AskUserQuestion
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
---

# Work on GitHub Issue

You are implementing a GitHub issue end-to-end. The issue number is: **$ARGUMENTS**

If no issue number is provided, ask the user for one before proceeding.

## Phase 0: Setup — Worktree & Branch

1. **Read the issue** with `gh issue view $ARGUMENTS` to understand requirements
2. **Create a worktree** using the `EnterWorktree` tool
3. **Immediately rename the branch** — `EnterWorktree` auto-names with a `worktree-` prefix that must be renamed before doing any other work. Feature branches must follow the `feature/<name>` format:
   ```bash
   git branch -m worktree-<auto-name> feature/<descriptive-branch-name>
   ```
4. **Assign and label the issue**:
   ```bash
   gh issue edit $ARGUMENTS --add-assignee @me
   gh issue edit $ARGUMENTS --add-label in-progress
   ```
5. **Link the branch to the issue** for traceability:
   ```bash
   gh issue develop $ARGUMENTS --branch feature/<descriptive-branch-name>
   ```
6. **Copy `tests/.env` from the main repo** (it's gitignored and missing in worktrees):
   ```bash
   MAIN_REPO_ROOT="$(git -C "$(git worktree list | head -1 | awk '{print $1}')" rev-parse --show-toplevel)"
   cp "$MAIN_REPO_ROOT/tests/.env" ./tests/.env
   ```

## Phase 1: Plan

Use `EnterPlanMode` to design the implementation before writing any code:

- Explore the codebase to understand existing patterns and conventions
- Identify all files that need to change
- Design the approach, considering edge cases
- Present the plan for user approval before proceeding

Do NOT skip planning. The plan catches design mistakes early.

## Phase 2: Write Tests First (TDD)

Write tests BEFORE implementing the feature:

- **New test files** go in `tests/` following the `test-<feature-name>.ps1` naming pattern
- Tests should cover all new functionality, edge cases, and backward compatibility
- Tests must invoke real functions where possible (dot-source `Common-SqlServerSchema.ps1` for shared helpers)
- Do NOT re-implement function logic locally in tests — test the actual code
- Follow existing test patterns (see `test-import-folder-ordering.ps1`, `test-exclude-feature.ps1`)

## Phase 3: Validate Test Failure

Run the new tests to confirm they fail (proving they actually test something):

```bash
pwsh -NoProfile -File tests/<test-file>.ps1
```

If tests pass before implementation, the tests are not testing the right thing — fix them.

## Phase 4: Start Docker SQL Server (if integration tests needed)

```bash
# Check if container is already running
docker ps --filter "name=sqlserver-test" --format "{{.Names}} {{.Status}}"

# Only start if not already running
cd tests && docker-compose up -d

# Wait for SQL Server to be ready (important!)
docker exec sqlserver-test /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'Test@1234' -C -Q "SELECT 1" -b 2>&1
```

NEVER run `docker-compose down` — other sessions may be using the container.

## Phase 5: Implement

- Write high-quality code following project conventions (see `.github/copilot-instructions.md`)
- No shortcuts, no TODOs, no placeholders — complete implementations only
- Follow existing patterns in the codebase
- Use `$script:` scope for cross-function state
- Use `[SUCCESS]`/`[ERROR]`/`[WARNING]`/`[INFO]` prefixes, no emojis
- Keep changes focused — don't refactor unrelated code

## Phase 6: Validate Success

Run ALL relevant tests to confirm everything passes:

```bash
# Run the new feature tests
pwsh -NoProfile -File tests/<test-file>.ps1

# Run integration tests if the change affects export/import behavior
pwsh -NoProfile -File tests/run-integration-test.ps1

# Run any other tests that might be affected
pwsh -NoProfile -File tests/<related-test>.ps1
```

All tests must pass. Existing tests must not break. Do not "fix" existing tests by weakening assertions.

## Phase 7: Self Code Review

Before declaring done, perform a thorough self-review. Use the `code-review` agents or manually check:

- [ ] No hardcoded values that should be configurable
- [ ] Error handling is complete (no silent failures)
- [ ] Edge cases are handled (null/empty inputs, missing files, old exports)
- [ ] No security vulnerabilities (SQL injection, command injection, path traversal)
- [ ] Code follows existing patterns and conventions in the codebase
- [ ] No dead code, unused variables, or commented-out blocks
- [ ] Function documentation (comment-based help) is accurate
- [ ] Tests actually test the real implementation (not re-implemented logic)
- [ ] Backward compatibility is preserved (old exports still work)
- [ ] PowerShell regex uses case-sensitive `[regex]::Replace()` where character case matters (PowerShell's `-replace` is case-insensitive by default)

## Phase 8: Documentation & Changelog

1. **Update `CHANGELOG.md`** following Keep a Changelog format:
   - Add entry under `## [Unreleased]` (or next version if known)
   - Categorize as Added/Changed/Fixed
   - Reference the issue number
   - Be specific about what changed and why

2. **Update other docs only if necessary**:
   - `README.md` — if new parameters, features, or usage patterns were added
   - `copilot-instructions.md` — if architectural patterns or conventions changed
   - `_DEPLOYMENT_README.md` template — if deployment order or folder structure changed

## Phase 9: Commit

Create a well-structured commit (or multiple commits for logically separate changes):

```bash
git add <specific-files>
git commit -m "feat: descriptive message (#$ARGUMENTS)"
```

Do NOT push unless the user explicitly asks. Do NOT add Co-Authored-By or Claude attribution.

## Important Reminders

- **Ask before proceeding** if requirements are ambiguous
- **Run integration tests** — do not skip them when changes affect export/import
- **Database names are hardcoded** (TestDb, TestDb_Dev, TestDb_Prod) — don't run parallel integration tests
- **Another reviewer will check this work** — quality matters
- **PowerShell `-replace` is case-insensitive** — use `[regex]::Replace($str, $pattern, $replacement, 'None')` when case sensitivity matters
