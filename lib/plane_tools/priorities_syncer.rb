# frozen_string_literal: true

module PlaneTools
  # Mirrors GitHub priority labels onto Plane work-item priorities.
  #
  # Behaviour:
  #  - Iterates the same GH-linked Plane work items as the comments
  #    syncer; skips work items whose GH issue is closed.
  #  - For each, reads the GH issue's labels and picks the highest-
  #    priority match from the project's `priorities:` map. Highest
  #    wins (urgent > high > medium > low) when multiple priority
  #    labels are set.
  #  - If the GH issue has no priority label, the Plane priority is
  #    left untouched (we don't reset to "none").
  #  - If Plane already has a non-"none" priority that disagrees with
  #    the GH-derived one:
  #      * by default, log the mismatch and leave Plane untouched
  #      * with overwrite: true, PATCH Plane to match GH
  #  - If Plane is "none" or matches, write/skip respectively.
  #  - Dry-run when apply: false; never mutates Plane.
  class PrioritiesSyncer
    Stats = Struct.new(:updated, :unchanged, :skipped_no_label, :skipped_no_config,
                       :mismatch_kept, :mismatch_overwritten, :skipped_closed,
                       keyword_init: true)

    attr_reader :stats

    def initialize(plane:, github:, log:, apply:, overwrite: false)
      @plane = plane
      @github = github
      @log = log
      @apply = apply
      @overwrite = overwrite
      @stats = Stats.new(
        updated: 0, unchanged: 0, skipped_no_label: 0, skipped_no_config: 0,
        mismatch_kept: 0, mismatch_overwritten: 0, skipped_closed: 0
      )
    end

    # Resolve a GH issue's priority labels through a project's label
    # map and return the matching Plane priority (e.g. "high"), or
    # nil if no label matches. Highest priority wins.
    def derive_priority(gh_issue, priority_map)
      label_names = gh_issue.labels.map(&:name)
      matches = label_names.filter_map { |n| priority_map[n] }
      return nil if matches.empty?

      matches.min_by { |p| Config::PRIORITY_RANK.index(p) || Config::PRIORITY_RANK.size }
    end

    def sync_work_item(project:, work_item:, label:, issue:, priority_map:)
      if priority_map.nil? || priority_map.empty?
        @stats.skipped_no_config += 1
        return
      end

      desired = derive_priority(issue, priority_map)
      if desired.nil?
        @log.debug "  #{label}: no priority label on GH issue; leaving Plane priority untouched"
        @stats.skipped_no_label += 1
        return
      end

      current = work_item["priority"].to_s
      if current == desired
        @log.debug "  #{label}: Plane priority already #{desired.inspect}; unchanged"
        @stats.unchanged += 1
      elsif current == "none" || current.empty?
        apply_priority(project, work_item, label, current, desired, :updated)
      elsif @overwrite
        apply_priority(project, work_item, label, current, desired, :mismatch_overwritten)
      else
        @log.warn "  #{label}: Plane priority=#{current.inspect} disagrees with GH-derived " \
                  "#{desired.inspect}; leaving Plane untouched (pass --overwrite-priorities to force)"
        @stats.mismatch_kept += 1
      end
    end

    def note_closed(label)
      @log.debug "  #{label}: GH issue closed; skipping priority sync"
      @stats.skipped_closed += 1
    end

    private

    def apply_priority(project, work_item, label, current, desired, stat_field)
      verb = stat_field == :mismatch_overwritten ? "OVERWRITE" : "set"
      if @apply
        @plane.patch_work_item(project["id"], work_item["id"], { priority: desired })
        @log.info "  #{label}: #{verb} Plane priority #{current.inspect} -> #{desired.inspect}"
      else
        @log.info "  #{label}: DRY-RUN would #{verb} Plane priority " \
                  "#{current.inspect} -> #{desired.inspect}"
      end
      @stats[stat_field] += 1
    end
  end
end
