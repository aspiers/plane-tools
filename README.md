# plane-tools

Tooling around [Plane.so](https://plane.so), in Ruby.

## What's here

### `bin/sync-gh-to-plane`

Mirrors state from GitHub issues into the corresponding Plane work
items. Iterates Plane work items linked to GH issues (via Plane's
`external_source=GITHUB` + `external_id=<gh issue number>`
mechanism), and for each one syncs:

1. **Comments** — every GitHub comment is upserted into Plane as a
   Plane comment with matching `external_id`.
2. **Priority** *(optional)* — the GitHub issue's priority label is
   translated to a Plane work-item priority (urgent / high / medium
   / low / none) per the project's `priorities:` map in
   `config/plane_github_map.yml`. Omit the map and priority sync is
   skipped automatically.

Behaviour highlights:

- **Idempotent.** Re-runs are cheap. Comments already present in
  Plane (matched by their GH comment id stored as `external_id`)
  are skipped if their rendered HTML is unchanged, and PATCHed in
  place if the rendering differs (e.g. the script's header format
  changed, or the GH user edited their comment). Priorities are
  only written when they actually need to change.
- **Backdated.** Plane's `created_at` on each mirrored comment is
  set to the original GH comment timestamp so chronology is
  preserved natively in Plane's UI.
- **Bot-aware.** Comments authored by GitHub Apps (`user.type ==
  "Bot"`) are filtered out. This is important: the official Plane
  GitHub integration posts "Synced with Plane Workspace 🔄"
  comments to GitHub from the `makeplane[bot]` account. Without
  this filter the script would mirror them back into Plane,
  creating noise.
- **Open issues only.** Closed/locked GH issues are skipped.
- **Highest priority wins.** If a GH issue has multiple priority
  labels (e.g. P0 and P1), the most urgent one (urgent > high >
  medium > low) is applied.
- **Mismatch-safe by default.** If Plane already has a non-"none"
  priority that disagrees with the GH-derived one, the script logs
  the mismatch and leaves Plane alone. Pass
  `--overwrite-priorities` to force GH to win.
- **Dry-run by default.** `--apply` is required to write.

#### Why the unidirectional-sync requirement

Plane's official GitHub integration supports bidirectional sync
(GitHub ↔ Plane). When bidirectional is active and this script
POSTs a new Plane comment, Plane sees the `external_id` link
back to a GitHub comment id and **updates that GitHub comment in
place** — gluing the script's "mirrored from GitHub" header onto
the original GitHub comment body. Not what you want.

The fix is to temporarily flip Plane's GitHub integration to
**unidirectional** (GitHub → Plane only) for the duration of the
import, then restore bidirectional afterwards. The script
prompts for an explicit confirmation when invoked with `--apply`
to make sure you've done this; pass `--yes` to skip the prompt
in unattended runs.

There is no public Plane API for toggling sync direction (the
toggle endpoint requires browser-session auth, not API keys), so
this step has to be manual via the Plane UI:

1. Plane Settings → Integrations → GitHub → edit the sync mapping
2. Set sync direction to unidirectional / GitHub → Plane only
3. Run the import
4. Restore bidirectional

#### Setup

Requires Ruby ~> 3.3 and bundler.

```bash
git clone https://github.com/aspiers/plane-tools
cd plane-tools
bundle install

cp .env.example .env
$EDITOR .env  # fill in PLANE_API_TOKEN, PLANE_WORKSPACE_SLUG, GITHUB_TOKEN

cp config/plane_github_map.example.yml config/plane_github_map.yml
$EDITOR config/plane_github_map.yml  # map your Plane projects -> GitHub repos
```

Get a Plane API token from Plane Settings → API tokens. The
GitHub token needs `repo` (read-only is sufficient) scope. If
`GITHUB_TOKEN` is unset the script falls back to `gh auth token`
from the [GitHub CLI](https://cli.github.com).

The `config/plane_github_map.yml` file maps each Plane project's
identifier (the short prefix shown in work item IDs, e.g. `D4D`
for `D4D-42`) to its corresponding GitHub repo as `owner/name`.
Two shapes are supported:

```yaml
# Legacy short form: just the repo (no priority sync)
PROJ: owner/repo

# Full form (priorities are optional)
ANOTHER:
  repo: owner/another-repo
  priorities:
    "P0 - critical": urgent
    "P1 - high": high
    "P2 - medium": medium
    "P3 - low": low
```

The keys under `priorities:` are GitHub label names; the values
are Plane priorities (one of `urgent`, `high`, `medium`, `low`,
`none`). Omit the `priorities:` section entirely to skip
priority sync for that project. If no project in the file has a
`priorities:` section, the priority syncer is skipped completely.

#### Usage

```bash
# Dry-run everything (no writes; prints planned operations)
bundle exec bin/sync-gh-to-plane

# Apply for real (after disabling bidirectional sync in Plane)
bundle exec bin/sync-gh-to-plane --apply

# Restrict scope
bundle exec bin/sync-gh-to-plane --project D4D
bundle exec bin/sync-gh-to-plane --project D4D --issue 161
bundle exec bin/sync-gh-to-plane --apply --limit 5

# Skip the confirmation prompt (for unattended runs)
bundle exec bin/sync-gh-to-plane --apply --yes

# Force GH priority to win when Plane already has a different value
bundle exec bin/sync-gh-to-plane --apply --overwrite-priorities
```

Output is mirrored to stdout and `tmp/sync-gh-to-plane.log`.

#### Library layout

The CLI is a thin wrapper around `lib/plane_tools/`:

- `config.rb` — `.env` + YAML loading
- `logging.rb` — tee-to-file logger
- `plane_client.rb` — Faraday wrapper, rate-limit pacer,
  endpoint helpers
- `github_client.rb` — Octokit + image-download Faraday clients
- `gh_renderer.rb` — Commonmarker → Plane-safe HTML +
  table-column-width injection
- `attachments.rb`, `image_rewriter.rb` — mirror GH-hosted
  images to Plane attachments
- `comments_syncer.rb` — comment-upsert loop
- `priorities_syncer.rb` — label → priority loop
- `cli.rb` — `OptionParser` + orchestration

## License

GPL v3. See [LICENSE](LICENSE).
