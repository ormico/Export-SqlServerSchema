# Changelog Instructions

## Applies To

- `CHANGELOG.md`

## Semantic Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR** (X.0.0): Breaking or incompatible API changes
- **MINOR** (x.Y.0): New features that are backwards compatible
- **PATCH** (x.y.Z): Bug fixes and minor improvements, backwards compatible

## Version Increment Decision Process

**ALWAYS reason through version selection explicitly** when updating the changelog. Present your analysis to the user before making the change.

### Ask These Questions

1. **Does this break existing functionality?**
   - Changed parameter names or removed parameters?
   - Changed default behavior that users rely on?
   - Changed output format in breaking ways?
   - Removed support for something?
   → If YES to any: **MAJOR version bump**

2. **Is this a significant new capability?**
   - Major new feature (e.g., parallel export, new import mode)?
   - New command/script added?
   - Significant architectural change?
   → If YES: Consider **MINOR version bump**

3. **Is this incremental improvement?**
   - Adding support for additional object types?
   - Bug fixes?
   - Performance improvements?
   - Documentation updates?
   - Code cleanup?
   → If YES: **PATCH version bump**

### Example Reasoning

```
Version Analysis:
- Breaking changes: None (all existing parameters work the same)
- New capability: Added CMK/CEK export (2 more object types)
- Scope: Incremental - similar to previous object type additions

Recommendation: PATCH (1.7.5 → 1.7.6)
Rationale: This adds support for 2 additional object types but doesn't 
introduce new commands, change interfaces, or add major features.
```

## Changelog Format

### Entry Structure

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- New features

### Changed
- Changes to existing functionality

### Fixed
- Bug fixes

### Deprecated
- Features to be removed in future

### Removed
- Removed features

### Security
- Security-related changes
```

### Writing Style

- Start each item with a verb (Added, Fixed, Changed, etc.)
- Be specific about what changed and why it matters
- Group related changes under bold headers
- Include code examples for significant features
- Reference issue numbers if applicable

## Previous Version Reference

Always check the most recent version in the changelog before suggesting a new version number. The version sequence must be incrementing.
