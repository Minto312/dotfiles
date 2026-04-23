---
description: "Review-fix loop: automatically review code, fix issues, and repeat until clean"
argument-hint: "[base ref for merge-base, e.g. 'origin/develop', or empty for auto-detect]"
---

# Auto Review Loop

Automatically review code, fix found issues, and re-review until clean. Maximum **3 iterations**.

## Configuration

- **Review agent**: Use the `code-reviewer` agent (from pr-review-toolkit plugin, Opus model)
- **Diff scope**: $ARGUMENTS (see below for default behavior)
- **Max iterations**: 3
- **Commit**: Do NOT commit during the loop. Only report results at the end.

## Determining Diff Scope

If `$ARGUMENTS` is provided, use it directly as the diff scope.

If `$ARGUMENTS` is empty, auto-detect the PR base branch:
1. Run `gh pr view --json baseRefName -q '.baseRefName'` to get the PR's base branch
2. If a PR exists, use that as `<base-branch>`
3. If no PR exists, try to detect the default base branch:
   - Check for `develop` branch: `git rev-parse --verify origin/develop`
   - If not found, check for `main`: `git rev-parse --verify origin/main`
   - If not found, check for `master`: `git rev-parse --verify origin/master`
4. If none of the above work, fall back to `git diff` (unstaged changes)

Once `<base-branch>` is determined, compute the diff scope using **merge-base**:
```bash
git diff $(git merge-base origin/<base-branch> HEAD)
```

**Why merge-base**: This compares the branch divergence point against the working tree, which:
- Includes uncommitted fixes from previous iterations (unlike `...HEAD` which only compares commits)
- Is unaffected by `origin/<base>` advancing after a fetch (unlike `git diff origin/<base>` which would show upstream changes as inverse diffs)

## Workflow

Execute the following loop up to 3 times:

### Step 1: Review

Launch a code-reviewer agent (via Task tool, subagent_type: general-purpose) with the following prompt. Make sure to pass the determined diff scope.

The agent should:
- Run `git diff <diff-scope>` to get the changes to review
- Review the changes following the code-reviewer guidelines (CLAUDE.md compliance, bug detection, code quality)
- Rate each issue with a confidence score (0-100)
- **Only report issues with confidence >= 80**
- Return a structured list of issues with file paths, line numbers, descriptions, and suggested fixes
- If no issues found, explicitly state "NO ISSUES FOUND"

### Step 2: Check Results

Parse the reviewer's response:
- If the reviewer found **no issues** (or stated "NO ISSUES FOUND"), **exit the loop** and go to the Summary step.
- If issues were found, proceed to Step 3.

### Step 3: Fix Issues

For each issue reported by the reviewer:
1. Read the relevant file
2. Apply the suggested fix (or implement a better fix if the suggestion is insufficient)
3. Verify the fix makes sense in context

**Important**: Do NOT fix issues you disagree with. Use your judgment. If a reported issue seems like a false positive, skip it.

### Step 4: Re-review

Go back to Step 1 for the next iteration. The reviewer will see the updated diff including your fixes.

**Important for re-review**: When launching the reviewer agent for iteration 2+, include the previous iteration's issues in the prompt context so the reviewer can verify they were addressed and focus on finding genuinely new issues rather than re-reporting variations of already-fixed problems.

## Summary

After the loop ends (either clean review or max iterations reached), report:

1. **Iterations completed**: How many review-fix cycles ran
2. **Issues found and fixed**: Each issue について以下を明記すること
   - **課題**: レビュワーが指摘した問題の内容（ファイルパス・行番号を含む）
   - **修正方針**: どのように修正したか、なぜその方針を選んだか
   - **スキップした場合**: 修正しなかった理由
3. **Remaining issues**: 最終レビューで残った未解決の指摘（理由付き）
4. **Status**: コードがクリーンか、未解決の指摘が残っているか

出力例:
```
### Iteration 1 (3 issues found)

1. [Critical] SQL injection vulnerability in `src/api/users.ts:42`
   - 課題: ユーザー入力がそのままSQLクエリに埋め込まれている
   - 修正方針: パラメータ化クエリに変更。ORMのプレースホルダー機能を使用

2. [Important] Missing null check in `src/utils/parse.ts:15`
   - 課題: parseResult が null の場合に例外が発生する
   - 修正方針: early return で null を処理し、呼び出し元の型定義も修正

3. [Important] Unused import in `src/components/App.tsx:3`
   - スキップ: リンターが検出する範囲のため対応不要と判断

### Iteration 2 (0 issues found)
Clean. No issues detected.
```

## Notes

- Do not commit or push during this process
- If the reviewer keeps finding new unrelated issues each iteration (not re-reports of the same issue), note this in the summary
- If a fix introduces a new issue caught in the next review, prioritize fixing the regression
- Keep fixes minimal and focused - do not refactor or improve code beyond what the reviewer flagged
