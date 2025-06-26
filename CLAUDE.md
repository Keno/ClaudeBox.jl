# ClaudeBox Development Notes

ClaudeBox is a sandboxed Julia REPL environment that provides a secure, isolated workspace with pre-installed development tools. It is particularly designed to sandbox claude-code (Anthropic's official CLI for Claude), allowing users to run Julia code, Node.js applications, and various command-line tools in a controlled environment while maintaining access to their local workspace directory. This sandboxing ensures that claude-code and other tools operate safely within defined boundaries.

## Important Reminders

### Manifest.toml
**DO NOT** check in the `Manifest.toml` file. This file should remain in `.gitignore` to avoid dependency resolution conflicts between different Julia versions and environments.

If you accidentally stage or commit `Manifest.toml`:
1. Remove it from git: `git rm --cached Manifest.toml`
2. Ensure it's in `.gitignore`
3. Commit the removal

### Shipping Code
When asked to "ship it":
1. Stage all changes: `git add -A`
2. Create a descriptive commit message
3. Push to the repository: `git push origin <branch>`
4. **IMPORTANT**: Monitor the GitHub Actions CI run to ensure it passes
   - Use: `gh run list --branch <branch> --limit 1` to find the run
   - Use: `gh run watch <run-id> --exit-status` to monitor it
   - If it fails, investigate and fix before considering the task complete

### Testing
Always run tests locally before pushing:
```bash
julia +nightly --project=. test/runtests.jl
```

### Dependencies
When adding new JLL dependencies:
1. Add to `Project.toml`
2. Update any relevant code that installs/uses the dependency
3. Run `julia +nightly --project=. -e "using Pkg; Pkg.resolve(); Pkg.instantiate()"`
4. Add tests to verify the dependency is properly installed

#### Adding Dependencies
**IMPORTANT**: Never manually edit UUIDs in Project.toml. Always use Pkg APIs to add dependencies:

```bash
# Add a regular dependency
julia +nightly --project=. -e "using Pkg; Pkg.add(\"PackageName\")"

# Add a test-only dependency
julia +nightly --project=. -e "using Pkg; Pkg.add(\"PackageName\"; target=:test)"

# Add from a specific source
julia +nightly --project=. -e "using Pkg; Pkg.add(url=\"https://github.com/org/Package.jl\", rev=\"main\")"
```

This ensures:
- Correct UUIDs are automatically resolved
- Dependencies are properly registered in the manifest
- Version compatibility is maintained
- Test dependencies are correctly placed in [extras]