# Claude Code Instructions

See `.github/copilot-instructions.md` for full project context, architecture, code conventions, and critical patterns. All instructions there apply here.

## Git workflow

### Worktrees and branch naming
`EnterWorktree` auto-names the branch with a `worktree-` prefix. Always rename it immediately after the worktree is created, before doing any other work:

```bash
git branch -m worktree-feature/<name> feature/<name>
```

Feature branches must follow the format `feature/<branch-name>`.

### Starting work on a GitHub issue
When beginning work on a GitHub issue, always do all of the following before writing any code:
1. **Assign** the issue to yourself (`gh issue edit <number> --add-assignee @me`)
2. **Label** it as in-progress (`gh issue edit <number> --add-label in-progress`)
3. **Link the branch** to the issue after creating it (`gh issue develop <number> --branch feature/<branch-name>` or manually via `gh api ...`)

These steps ensure visibility into active work and traceability from issue to branch to PR.
