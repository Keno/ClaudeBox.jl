# ClaudeBox Development Notes

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