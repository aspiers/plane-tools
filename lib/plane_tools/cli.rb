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

      comments = CommentsSyncer.new(
        plane: plane, github: github, my_user_id: my_user_id,
        log: log, apply: @options[:apply], limit: @options[:limit]
      )

      sync_all_projects(config, projects_by_id, plane, github, comments, log)
      summarise(log, comments)
    end

    private

    def sync_all_projects(config, projects_by_id, plane, github, comments, log)
      config.each_project do |proj_identifier, entry|
        next if @options[:project] && @options[:project] != proj_identifier
        break if comments.limit_hit?

        project = projects_by_id[proj_identifier]
        unless project
          log.warn "project #{proj_identifier} not found in workspace #{config.plane_slug}; skipping"
          next
        end

        repo = entry[:repo]
        log.info "=== project #{proj_identifier} (#{project['id']}) -> #{repo} ==="

        work_items = plane.github_work_items(project["id"])
        log.info "  #{work_items.size} GH-linked work item(s)"

        sync_project_work_items(project, repo, work_items, github, comments, log)
      end
    end

    def sync_project_work_items(project, repo, work_items, github, comments, log)
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
          next
        end

        comments.sync_work_item(
          project: project, repo: repo, work_item: wi, label: label, issue: issue
        )
      end
    end

    def fetch_issue(github, repo, gh_num, label, log)
      github.issue(repo, gh_num)
    rescue Octokit::NotFound
      log.warn "  #{label}: GH issue not found in #{repo}; skipping"
      nil
    end

    def parse_options(argv)
      opts = { project: nil, issue: nil, limit: nil, apply: false, yes: false }
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

    def summarise(log, comments)
      c = comments.stats
      log.info "comments: posted=#{c.posted} patched=#{c.patched} " \
               "unchanged=#{c.unchanged} foreign=#{c.foreign} skipped=#{c.skipped}"
      log.info "DONE (mode=#{@options[:apply] ? 'APPLY' : 'DRY-RUN'}, limit=#{@options[:limit].inspect})"
    end
  end
end
