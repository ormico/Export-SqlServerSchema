# Claude Code Instructions

See `.github/copilot-instructions.md` for full project context, architecture, code conventions, and critical patterns. All instructions there apply here.

## Git workflow

### Worktrees and branch naming
`EnterWorktree` auto-names the branch with a `worktree-` prefix. Always rename it immediately after the worktree is created, before doing any other work:

```bash
git branch -m worktree-feature/<name> feature/<name>
```

Feature branches must follow the format `feature/<branch-name>`.
