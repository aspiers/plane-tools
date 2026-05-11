# frozen_string_literal: true

module PlaneTools
  # Mirrors GH issue comments into the corresponding Plane work item.
  # See README.md for the high-level behaviour (idempotent, backdated,
  # bot-aware, open-only, dry-run by default).
  class CommentsSyncer
    Stats = Struct.new(:posted, :patched, :unchanged, :foreign, :skipped, keyword_init: true)

    attr_reader :stats

    def initialize(plane:, github:, my_user_id:, log:, apply:, limit: nil)
      @plane = plane
      @github = github
      @my_user_id = my_user_id
      @log = log
      @apply = apply
      @limit = limit
      @stats = Stats.new(posted: 0, patched: 0, unchanged: 0, foreign: 0, skipped: 0)
      @limit_hit = false
    end

    def limit_hit? = @limit_hit

    # Syncs comments for one (Plane project, GH repo, work item).
    # Returns nothing useful; mutates @stats and @limit_hit.
    def sync_work_item(project:, repo:, work_item:, label:, issue:)
      existing = @plane.comments(project["id"], work_item["id"])
      by_gh_id = existing.select { |c| c["external_source"] == "GITHUB" }
                         .each_with_object({}) { |c, h| h[c["external_id"].to_s] = c }
      @log.info "  #{label}: #{existing.size} existing Plane comments " \
                "(#{by_gh_id.size} already mirrored from GH)"

      image_rewriter = ImageRewriter.build(
        plane: @plane, github: @github,
        project_id: project["id"], work_item_id: work_item["id"],
        log: @log, apply: @apply
      )

      here = Stats.new(posted: 0, patched: 0, unchanged: 0, foreign: 0, skipped: 0)
      @github.issue_comments(repo, issue.number).each do |c|
        break if @limit_hit

        process_one_comment(project, work_item, c, by_gh_id, image_rewriter, here, repo)
      end

      @log.info "  #{label}: posted=#{here.posted} patched=#{here.patched} " \
                "unchanged=#{here.unchanged} foreign=#{here.foreign} skipped=#{here.skipped}"
    end

    private

    def process_one_comment(project, work_item, c, by_gh_id, image_rewriter, here, repo)
      cid = c.id.to_s

      if c.user&.type == "Bot"
        @log.debug "    skip gh_comment #{cid}: bot author (#{c.user.login})"
        bump(:skipped, here)
        return
      end

      rendered = GhRenderer.render(c, image_rewriter: image_rewriter, repo: repo)
      existing_plane = by_gh_id[cid]

      if existing_plane && existing_plane["created_by"] != @my_user_id
        # Comment created by another Plane user (e.g. Plane's GH
        # integration); we can't PATCH it (Plane returns 403). Skip
        # and leave whatever they have in place.
        @log.warn "    foreign gh_comment #{cid}: " \
                  "created by #{existing_plane['created_by']&.[](0, 8)}, skipping"
        bump(:foreign, here)
      elsif existing_plane.nil?
        post_new(project, work_item, c, cid, rendered, here)
      elsif existing_plane["comment_html"] == rendered
        @log.debug "    unchanged gh_comment #{cid}"
        bump(:unchanged, here)
      else
        patch_existing(project, work_item, c, cid, rendered, existing_plane, here)
      end
    end

    def post_new(project, work_item, c, cid, rendered, here)
      payload = {
        comment_html: rendered,
        external_source: "GITHUB",
        external_id: cid,
        access: "INTERNAL",
        created_at: c.created_at.iso8601
      }
      if @apply
        @plane.post_comment(project["id"], work_item["id"], payload)
        @log.info "    POSTed gh_comment #{cid} by @#{c.user.login}"
      else
        @log.info "    DRY-RUN would POST gh_comment #{cid} by @#{c.user.login} " \
                  "(#{c.body.to_s.length} chars md -> #{rendered.length} chars html)"
      end
      bump(:posted, here)
      check_limit
    end

    def patch_existing(project, work_item, c, cid, rendered, existing_plane, here)
      payload = { comment_html: rendered, created_at: c.created_at.iso8601 }
      if @apply
        @plane.patch_comment(project["id"], work_item["id"], existing_plane["id"], payload)
        @log.info "    PATCHed gh_comment #{cid} by @#{c.user.login} " \
                  "(plane comment #{existing_plane['id'][0, 8]})"
      else
        @log.info "    DRY-RUN would PATCH gh_comment #{cid} by @#{c.user.login} " \
                  "(plane comment #{existing_plane['id'][0, 8]}, " \
                  "#{existing_plane['comment_html'].length} -> #{rendered.length} chars html)"
      end
      bump(:patched, here)
      check_limit
    end

    def bump(field, here)
      here[field] += 1
      @stats[field] += 1
    end

    def check_limit
      return unless @limit

      @limit_hit = (@stats.posted + @stats.patched) >= @limit
    end
  end
end
