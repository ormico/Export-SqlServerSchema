---
description: Markdown documentation standards and best practices for the Export-SqlServerSchema project.
applyTo: "**/*.md"
---

# Markdown Documentation Standards

**Project**: Export-SqlServerSchema
**Context**: These instructions apply to all Markdown documentation files in this repository.

## 1. General Formatting

-   **Headers**: Use ATX-style headers (`#`, `##`, `###`). Avoid Setext headers (underlined).
-   **Line Wrap**: Soft-wrap is preferred. Do not hard-wrap lines unless necessary for table formatting.
-   **Lists**: Use dashes `-` for unordered lists, not asterisks `*`.
-   **Code Blocks**: Always specify the language for syntax highlighting (e.g., ` ```powershell `, ` ```sql `, ` ```yaml `).

## 2. Project Structure & Linking

-   **Location**: detailed documentation goes in `docs/`. Root `README.md` is for quick start and high-level overview.
-   **Links**: Use relative links.
    -   Link to files: `[Link Text](path/to/file.md)`
    -   Link to testing docs: `[Testing Guide](../tests/README.md)` (from `docs/`)
-   **Images**: internal images should go in `docs/images/`.

## 3. Admonitions & Callouts

Since GitHub Markdown doesn't support generic extensive admonitions, use the following conventions:

-   **Bold prefix** for importance:
    -   `**Note**:`
    -   `**Warning**:`
    -   `**Tip**:`

Example:
> **Note**: This feature is currently in beta.

## 4. Documentation Types

### 4.1 User Guides (`docs/USER_GUIDE.md`)
-   Focus on *how-to* and *usage*.
-   Include concrete code examples.
-   Explain configuration options clearly with YAML snippets.

### 4.2 Design Documents (`docs/SOFTWARE_DESIGN.md`)
-   Focus on *architecture*, *internal logic*, and *decision making*.
-   Explain the "Why" (e.g., why 21 folders? why 2 passes?).
-   Include directory structure diagrams.

### 4.3 Change Logs (`CHANGELOG.md`)
-   Keep specific version history in the root `CHANGELOG.md`.

## 5. Tone
-   Professional but accessible.
-   Clear, concise sentences.
-   Address the user directly ("You can configure...").
