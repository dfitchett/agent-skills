---
name: pr-description
description: Generate a pull request description markdown file from the repository's PR template, auto-filled with context from git diff and commit history. Use when the user says "write a PR description", "fill out the PR template", "create a PR description", "draft a PR", "make a PR doc", or asks you to prepare a pull request. Also trigger when the user says "/pr-description" or references preparing changes for review. Works with any repository that has a PR template.
---

# PR Description Generator

Generate a ready-to-use pull request description by finding the repo's PR template and filling it in with context from the current branch's changes.

## Workflow

### 1. Find the PR template

Search for PR templates in these locations:

```
.github/PULL_REQUEST_TEMPLATE.md
.github/pull_request_template.md
.github/PULL_REQUEST_TEMPLATE/*.md
docs/pull_request_template.md
pull_request_template.md
PULL_REQUEST_TEMPLATE.md
```

**If multiple templates are found** (common with `.github/PULL_REQUEST_TEMPLATE/` directories that contain `bug_fix.md`, `feature.md`, etc.), present the list to the user and let them pick which one to use.

If no template is found, tell the user and ask if they'd like a generic PR description instead.

### 2. Gather context

Run these git commands in parallel to collect the information needed to fill out the template:

- `git status` — see what files are changed and whether there are uncommitted changes
- `git diff --stat` — summary of what changed (vs the base branch if on a feature branch)
- `git log --oneline <base>..HEAD` — all commits on this branch (use `main` or `master` as base, whichever exists)
- `git diff <base>...HEAD` — the full diff of everything on this branch
- `basename $(git rev-parse --show-toplevel)` — the repo name, used for the output path

To detect the base branch, check which of `main` or `master` exists:
```bash
git rev-parse --verify main 2>/dev/null && echo "main" || echo "master"
```

If the branch has many commits or a large diff, focus on understanding the overall intent rather than cataloging every line. Read the commit messages — they often capture the "why" better than the diff.

### 3. Determine output location

Save the file to `temp/<repo-name>/` relative to the workspace root (the parent of the git repo, or the repo root itself if there's no workspace).

**File naming convention:** The filename is based on the issue/ticket number(s). Try to extract them automatically from the branch name, commit messages, or user context. Look for common patterns: `#123`, `PROJ-456`, bare numbers at the start of branch names (e.g., `12345-fix-thing`), or GitHub issue URLs.

- Single issue: `pr-description-12345.md`
- Multiple issues: `pr-description-12345-12346-12347.md`

**If no issue number can be extracted**, ask the user how they'd like to name the file. Present these options:
1. Provide the issue number(s)
2. Use the branch name (e.g., `pr-description-fix-bolding-in-need-help.md`)
3. Type a custom name

### 4. Fill out the template

Read the PR template and fill in each section based on the gathered context. The goal is a description that a reviewer can read and immediately understand what changed and why.

**Guiding principles:**
- Be specific about what changed, not generic. "Updated the login flow to use OAuth2 instead of session cookies" is better than "Made improvements to authentication."
- The summary should answer: What changed? Why? What does a reviewer need to know?
- For related issues, link any ticket numbers found in branch names or commit messages (patterns like `#123`, `PROJ-456`, or URLs)
- For testing sections, describe what was actually tested — if you can see test files in the diff, reference them. If not, note what testing the author should verify before submitting.
- For checklist items, check the ones that are clearly satisfied based on the diff (e.g., "unit tests added" if test files are in the diff). Leave unchecked items the author needs to verify manually.
- If a section isn't applicable, write "N/A" or a brief note explaining why, rather than leaving it blank.

**Tone:** Write as if you're the author of the PR explaining your own changes to a colleague. Professional but not stiff. Match the tone of the existing template — if it's casual, be casual.

### 5. Present the result and offer to create the PR

After writing the file, tell the user:
- The file path
- A brief note about any sections they should review or fill in manually (e.g., "I left the screenshots section for you to fill in" or "Double-check the related issues — I found #123 in the branch name but there may be others")

Then ask the user if they'd like to create the PR now. If yes:
1. Confirm the target base branch (default to `main` or `master`)
2. Push the current branch if it hasn't been pushed yet (`git push -u origin <branch>`)
3. Create a draft PR using `gh pr create --draft`, passing the generated description as the body
4. Return the PR URL to the user
