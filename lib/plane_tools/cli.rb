# frozen_string_literal: true

module PlaneTools
  # Top-level orchestrator. Bin scripts delegate here.
  class CLI
    def self.run(argv, root:)
      new(argv, root: root).run
    end

    def initialize(argv, root:)
      @argv = argv
      @root = root
      @options = parse_options(argv)
    end

    def run
      config = Config.load(@root)
      log = Logging.build(root: @root, name: "sync-gh-to-plane")

      mode_banner(log, config)
      confirm_sync_mode(log) if @options[:apply] && !@options[:yes]

      plane = PlaneClient.new(
        token: config.plane_token, slug: config.plane_slug, base_url: config.plane_base
      )
      github = GithubClient.new(token: config.github_token)

      projects_by_id = plane.projects.each_with_object({}) { |p, h| h[p["identifier"]] = p }
      log.info "discovered Plane projects: #{projects_by_id.keys.inspect}"

      me = plane.me
      my_user_id = me["id"]
      log.info "authenticated as Plane user #{my_user_id} (#{me['email']})"

      do_priorities = config.priorities_configured?
      log.info(
        do_priorities ? "priority sync: ENABLED (priorities: map present)" : "priority sync: skipped (no priorities: map in config)"
      )

      gh_to_plane_index, work_items_by_project = build_gh_to_plane_index(
        config, projects_by_id, plane, log
      )

      comments = CommentsSyncer.new(
        plane: plane, github: github, my_user_id: my_user_id,
        log: log, apply: @options[:apply], limit: @options[:limit],
        gh_to_plane_index: gh_to_plane_index, plane_web_base: config.plane_web_base
      )
      priorities = PrioritiesSyncer.new(
        plane: plane, github: github,
        log: log, apply: @options[:apply],
        overwrite: @options[:overwrite_priorities]
      )

      sync_all_projects(
        config, projects_by_id, work_items_by_project,
        plane, github, comments, priorities, do_priorities, log
      )
      summarise(log, comments, priorities, do_priorities)
    end

    # Build a "<repo>#<external_id>" -> { project_identifier:,
    # sequence_id:, slug: } index of every GH-linked Plane work
    # item across every project named in the YAML map. Used to
    # decorate cross-ref hyperlinks in mirrored comments with a
    # second link to the Plane sibling.
    #
    # Returns [index, work_items_by_project_id] so the main sync
    # loop can re-use the per-project work-item listings instead
    # of fetching them a second time.
    def build_gh_to_plane_index(config, projects_by_id, plane, log)
      index = {}
      work_items_by_project = {}
      config.each_project do |proj_identifier, entry|
        project = projects_by_id[proj_identifier]
        next unless project

        wis = plane.github_work_items(project["id"])
        work_items_by_project[project["id"]] = wis
        repo = entry[:repo]
        wis.each do |wi|
          gh_num = wi["external_id"].to_i
          next unless gh_num.positive?

          index["#{repo}##{gh_num}"] = {
            project_identifier: proj_identifier,
            sequence_id: wi["sequence_id"],
            slug: config.plane_slug
          }
        end
      end
      log.info "built GH->Plane index: #{index.size} mirrored work item(s) across " \
               "#{work_items_by_project.size} project(s)"
      [index, work_items_by_project]
    end

    private

    # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
    def sync_all_projects(config, projects_by_id, work_items_by_project, plane, github, comments, priorities, do_priorities, log)
      config.each_project do |proj_identifier, entry|
        next if @options[:project] && @options[:project] != proj_identifier
        break if comments.limit_hit?

        project = projects_by_id[proj_identifier]
        unless project
          log.warn "project #{proj_identifier} not found in workspace #{config.plane_slug}; skipping"
          next
        end

        repo = entry[:repo]
        priority_map = entry[:priorities]
        log.info "=== project #{proj_identifier} (#{project['id']}) -> #{repo} ==="

        work_items = work_items_by_project.fetch(project["id"]) { plane.github_work_items(project["id"]) }
        log.info "  #{work_items.size} GH-linked work item(s)"

        sync_project_work_items(
          project, repo, work_items, priority_map,
          github, comments, priorities, do_priorities, log
        )
      end
    end

    def sync_project_work_items(project, repo, work_items, priority_map, github, comments, priorities, do_priorities, log)
      work_items.each do |wi|
        break if comments.limit_hit?

        gh_num = wi["external_id"].to_i
        next if @options[:issue] && @options[:issue] != gh_num

        if gh_num <= 0
          log.warn "  work item #{wi['id']} has unparseable external_id #{wi['external_id'].inspect}; skipping"
          next
        end

        label = "#{project['identifier']}-#{wi['sequence_id']} (gh##{gh_num})"
        issue = fetch_issue(github, repo, gh_num, label, log)
        next if issue.nil?

        if issue.state != "open"
          log.info "  #{label}: GH state=#{issue.state}, skipping (open-only)"
          priorities.note_closed(label) if do_priorities
          next
        end

        comments.sync_work_item(
          project: project, repo: repo, work_item: wi, label: label, issue: issue
        )

        next unless do_priorities

        priorities.sync_work_item(
          project: project, work_item: wi, label: label,
          issue: issue, priority_map: priority_map
        )
      end
    end
    # rubocop:enable Metrics/ParameterLists,Metrics/MethodLength

    def fetch_issue(github, repo, gh_num, label, log)
      github.issue(repo, gh_num)
    rescue Octokit::NotFound
      log.warn "  #{label}: GH issue not found in #{repo}; skipping"
      nil
    end

    def parse_options(argv)
      opts = { project: nil, issue: nil, limit: nil, apply: false, yes: false, overwrite_priorities: false }
      OptionParser.new do |op|
        op.banner = "Usage: bin/sync-gh-to-plane [options]"
        op.on("--project ID", "Restrict to one Plane project identifier (e.g. D4D)") { |v| opts[:project] = v }
        op.on("--issue NUM", Integer, "Restrict to one GH issue number") { |v| opts[:issue] = v }
        op.on("--limit N", Integer, "Stop after N comments would-be/are POSTed (across all work items)") do |v|
          opts[:limit] = v
        end
        op.on("--apply", "Actually POST/PATCH. Without this, runs as dry-run.") { opts[:apply] = true }
        op.on("--yes", "Skip the interactive sync-mode confirmation prompt (for unattended runs)") do
          opts[:yes] = true
        end
        op.on("--overwrite-priorities",
              "Overwrite Plane priorities that disagree with GH (default: keep Plane, log mismatch)") do
          opts[:overwrite_priorities] = true
        end
        op.on("-h", "--help") do
          puts op
          exit 0
        end
      end.parse!(argv)
      opts
    end

    def mode_banner(log, config)
      log.info "loaded project map: #{config.project_map.inspect}"
      log.info "MODE: #{@options[:apply] ? 'APPLY (will POST/PATCH)' : 'DRY-RUN (no writes)'}"
    end

    def confirm_sync_mode(log)
      $stdout.puts <<~WARN

        ============================================================
        BEFORE PROCEEDING:
          In Plane, set the GitHub integration sync mode for this
          workspace to UNIDIRECTIONAL (GitHub -> Plane only).
          Otherwise the imported comments may round-trip back to
          GitHub and pollute the original GH comment bodies.

        AFTER this script finishes, restore BIDIRECTIONAL sync.

        Type 'unidirectional' to confirm sync is currently OFF
        (Plane -> GitHub disabled), or anything else to abort:
        ============================================================
      WARN
      $stdout.print "> "
      $stdout.flush
      reply = $stdin.gets&.strip
      unless reply == "unidirectional"
        log.error "aborted: confirmation not given (got #{reply.inspect})"
        exit 1
      end
      log.info "sync-mode confirmation accepted"
    end

    def summarise(log, comments, priorities, do_priorities)
      c = comments.stats
      log.info "comments: posted=#{c.posted} patched=#{c.patched} " \
               "unchanged=#{c.unchanged} foreign=#{c.foreign} skipped=#{c.skipped}"
      if do_priorities
        p = priorities.stats
        log.info "priorities: updated=#{p.updated} unchanged=#{p.unchanged} " \
                 "no_label=#{p.skipped_no_label} no_config=#{p.skipped_no_config} " \
                 "mismatch_kept=#{p.mismatch_kept} mismatch_overwritten=#{p.mismatch_overwritten} " \
                 "closed=#{p.skipped_closed}"
      end
      log.info "DONE (mode=#{@options[:apply] ? 'APPLY' : 'DRY-RUN'}, limit=#{@options[:limit].inspect})"
    end
  end
end
