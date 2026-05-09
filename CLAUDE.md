# Conventional Commits Rules

This repo enforces [Conventional Commits](https://www.conventionalcommits.org/) via GitHub action.

## Required Format

```
<type>(<scope>): <description>
```

**The colon `:` after type/scope is mandatory.**

## Allowed Types

- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation
- `style` - Formatting, missing semicolons, etc.
- `refactor` - Code restructuring
- `test` - Adding/updating tests
- `build` - Build system changes
- `perf` - Performance improvements
- `ci` - CI configuration changes
- `chore` - Maintenance tasks
- `revert` - Revert previous commit
- `merge` - Merge commit (auto-allowed)
- `wip` - Work in progress

## Optional Elements

- `(scope)` - Component affected, e.g., `fix(git_buffer_store):`
- `!` - Breaking change indicator, e.g., `feat!:` or `fix(user)!:`

## Examples

✅ **Valid:**
```
feat: Add buffer_hunk_reset functionality
fix(git_buffer_store): Prevent autocmd accumulation
perf(Spawn): Fix O(N²) string parsing
feat!: Change all the things
```

❌ **Invalid:**
```
multi: Add buffer_hunk_reset          (multi not in allowed types)
Spawn: Fix O(N²) string parsing       (Spawn not in allowed types, missing :)
Added new feature                     (no type: prefix)
```

## Notes

- `multi` is NOT a standard type - use `feat`/`fix`/`refactor` instead
- Scope can be component name or left out entirely
- Breaking changes use `!` before the colon
