# GitHub Actions CI/CD Workflows

This directory contains the CI/CD workflows for Export-SqlServerSchema.

## Workflows

### ci-pr.yml - Pull Request Testing

**Triggers**: Pull requests to `main` or `develop` branches

**Purpose**: Validates code changes through automated testing

**Steps**:
1. Checkout code
2. Setup PowerShell environment
3. Install required PowerShell modules (SqlServer, powershell-yaml)
4. Start SQL Server 2022 Docker container
5. Run integration test suite (`tests/run-integration-test.ps1`)
6. Run exclusion feature tests (`tests/test-exclude-feature.ps1`)
7. Cleanup Docker resources
8. Upload test artifacts on failure

**What it validates**:
- Export functionality with all 21 object types
- Dev mode import (schema-only, infrastructure skipped)
- Prod mode import (full infrastructure with FileGroups)
- Cross-platform FileGroup deployment
- Data integrity and FK constraints
- MAXDOP and Security Policy configuration
- Exclude object types feature coverage

### ci-main.yml - Main Branch & Release

**Triggers**: 
- Pushes to `main` branch
- Tags matching `v*.*.*` pattern
- Manual workflow dispatch

**Purpose**: Runs tests and creates releases for tagged versions

**Jobs**:

1. **Version Job**:
   - Uses GitVersion to calculate semantic version
   - Detects if triggered by a tag
   - Outputs version information for downstream jobs

2. **Test Job**:
   - Same integration tests as PR workflow
   - Validates main branch stability

3. **Release Job** (only for tags):
   - Creates release directory with version file
   - Copies release artifacts:
     - CHANGELOG.md
     - export-import-config.example.yml
     - export-import-config.schema.json
     - Export-SqlServerSchema.ps1
     - Import-SqlServerSchema.ps1
     - LICENSE.md
     - README.md
   - Creates ZIP archive: `Export-SqlServerSchema-v{version}.zip`
   - Extracts release notes from CHANGELOG.md
   - Creates GitHub Release with artifact
   - Uploads release artifacts (90-day retention)

## GitVersion Configuration

**File**: `GitVersion.yml` (root directory)

**Strategy**: Continuous Delivery mode with semantic versioning

**Branch Configuration**:
- **main**: Release branch, patch increment, no tag suffix
- **develop**: Development branch, minor increment, `alpha` tag
- **feature**: Feature branches, inherit increment, branch name tag
- **hotfix**: Hotfix branches, patch increment, `beta` tag
- **release**: Release branches, no increment, `beta` tag

**Version Bump Triggers** (via commit messages):
- `+semver: major` or `+semver: breaking` - Major version bump
- `+semver: minor` or `+semver: feature` - Minor version bump
- `+semver: patch` or `+semver: fix` - Patch version bump
- `+semver: none` or `+semver: skip` - No version bump

**Tag Prefix**: `v` (e.g., `v1.1.0`)

## Creating a Release

### Automated Release (Recommended)

1. Ensure all changes are merged to `main`
2. Ensure `CHANGELOG.md` is updated with release notes
3. Create and push a version tag:
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
4. GitHub Actions will automatically:
   - Run integration tests
   - Create release ZIP archive
   - Create GitHub Release with notes from CHANGELOG.md
   - Attach ZIP file to release

### Manual Release

Trigger the workflow manually from GitHub Actions UI:
1. Go to Actions → CI - Main Branch
2. Click "Run workflow"
3. Select `main` branch
4. Click "Run workflow"

Note: Manual runs won't create a release unless triggered by a tag.

## Testing Locally

### Test PR Workflow

```powershell
# Navigate to tests directory
cd tests

# Start Docker containers
docker-compose up -d

# Wait for SQL Server to be ready
Start-Sleep 30

# Run integration tests
pwsh ./run-integration-test.ps1

# Cleanup
docker-compose down -v
```

### Test Release Archive Creation

```powershell
# Create release directory
mkdir release

# Copy files
cp CHANGELOG.md, export-import-config.example.yml, export-import-config.schema.json, `
   Export-SqlServerSchema.ps1, Import-SqlServerSchema.ps1, LICENSE.md, README.md release/

# Create ZIP
Compress-Archive -Path release\* -DestinationPath Export-SqlServerSchema-v1.1.0.zip
```

## Requirements

### GitHub Secrets

No secrets required for public repositories. For private repositories, ensure `GITHUB_TOKEN` has:
- `contents: write` permission for creating releases

### Docker

PR and main workflows require GitHub-hosted runners with Docker support (included in `ubuntu-latest`).

### PowerShell Modules

Automatically installed in workflows:
- `SqlServer` - SMO (SQL Server Management Objects)
- `powershell-yaml` - YAML configuration support

## Troubleshooting

### Test Failures

1. Check Docker logs: `docker-compose logs sqlserver`
2. Verify SQL Server readiness: `docker-compose ps`
3. Review test artifacts uploaded on failure

### Release Not Created

1. Verify tag format: Must match `v*.*.*` (e.g., `v1.1.0`)
2. Check if tests passed: Release job depends on test job
3. Verify CHANGELOG.md contains release section: `## [1.1.0]`

### GitVersion Issues

1. Ensure GitVersion.yml is in repository root
2. Verify branch naming matches regex patterns
3. Check commit history is fetched (`fetch-depth: 0`)

## Maintenance

### Updating Workflows

When modifying workflows:
1. Test changes in a feature branch first
2. PR workflow will validate syntax
3. Review GitHub Actions logs for any issues

### Updating GitVersion

Modify `GitVersion.yml` to adjust:
- Branch strategies
- Version increment rules
- Tag prefixes
- Commit message patterns

See [GitVersion documentation](https://gitversion.net/docs/) for advanced configuration.
