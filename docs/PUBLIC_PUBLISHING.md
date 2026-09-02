# Public publishing workflow

`NDS4MiSTer` is a public source repository. Treat every committed byte and every
deleted historical byte as permanently public.

## Repository boundary

- Only push from the dedicated clean checkout.
- Never add the public GitHub remote to a development worktree.
- Copy or port only reviewed source changes into the clean checkout. Do not copy
  an entire development workspace, build directory, home directory, or SD-card
  directory.
- Commercial ROMs, saves, BIOS dumps, console keys, build outputs, captures,
  compiled binaries, release archives, credentials, and personal paths are not
  source and must never enter Git history.
- Compiled public-beta files belong on the GitHub Releases page after their ZIP
  and checksum have been reviewed; they do not belong in the source branch.

## One-time local setup

The clean checkout uses a dedicated SSH key, the `SplashDev88` GitHub noreply
identity, and versioned Git hooks:

```sh
git config --local user.name SplashDev88
git config --local user.email YOUR_GITHUB_NOREPLY_ADDRESS
git config --local user.useConfigOnly true
git config --local core.hooksPath .githooks
git config --local push.default simple
git config --local pull.ff only
git config --local fetch.prune true
```

Keep the dedicated `core.sshCommand` already configured in this checkout. Do
not copy private email addresses or key material into versioned files.

## Every public commit

1. Stage only intentional files with `git add FILE...`; do not use `git add -A`
   from an unreviewed directory.
2. Review the exact staged names and content:

   ```sh
   git status --short
   git diff --cached --stat
   git diff --cached
   python3 tools/audit_public_repo.py --self-test --staged
   ```

3. Commit. The pre-commit hook rechecks the staged blobs and local noreply
   identity.
4. Before pushing, inspect the outgoing commits:

   ```sh
   git log --oneline --decorate origin/main..HEAD
   git diff --stat origin/main...HEAD
   python3 tools/audit_public_repo.py --self-test --tracked --history
   ```

5. Push normally with `git push`. The pre-push hook rejects unexpected remotes,
   ref deletion, force pushes, forbidden files, unsafe historical objects, and
   non-noreply commit metadata.

Never bypass a failed hook with `--no-verify`. Diagnose the failure instead.

## Every public release

Build the installable ZIP outside this source checkout. Before uploading it,
run the strict package audit with both the ZIP and its sidecar:

```sh
python3 tools/audit_public_release.py \
  /path/to/NDS4MiSTer_Public_Beta.zip \
  --sidecar /path/to/NDS4MiSTer_Public_Beta.zip.sha256
```

The audit accepts only the documented MiSTer installation structure, exactly
one dated NDS RBF, the Kickstart launcher, the ARM service and its checksum,
the README, licenses, and complete internal hashes. It rejects traversal,
links, unexpected files, ROM/save/private extensions, personal paths and
emails, credentials, corrupt archives, and checksum mismatches.

## GitHub settings

- Keep the repository public only because the curated tree is designed for
  publication.
- Keep GitHub email privacy and user push protection enabled.
- Keep secret-scanning alerts enabled.
- Protect `main` with a ruleset that blocks force pushes and requires the
  `audit` status check before merging.
- Review the complete release page and download its artifacts from a signed-out
  browser before announcing a release.

If a private file ever reaches GitHub, deleting it in a later commit is not
enough. Immediately revoke exposed credentials, stop publishing, and rewrite
the affected Git history before continuing.
