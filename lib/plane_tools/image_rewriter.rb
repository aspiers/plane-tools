# frozen_string_literal: true

module PlaneTools
  # Builds a callable that rewrites <img src=GH_URL> tags to
  # <img src=PLANE_URL> for a given work item. Idempotent:
  # existing GH-mirrored attachments (matched by external_id)
  # are reused, never re-uploaded.
  class ImageRewriter
    # GH-hosted image URLs we mirror to Plane attachments. Other image
    # hosts (imgur etc.) pass through untouched.
    GH_IMAGE_HOST_RE = %r{\Ahttps://(?:github\.com/user-attachments/assets/|
                                     [^/]*githubusercontent\.com/)}x

    def self.build(plane:, github:, project_id:, work_item_id:, log:, apply:)
      existing = plane.attachments(project_id, work_item_id)
                      .select { |a| a["external_source"] == "GITHUB" && a["external_id"] }
                      .each_with_object({}) do |a, h|
        h[a["external_id"]] = a["asset"] && asset_url_for(plane.slug, a)
      end
      cache = existing.dup

      lambda do |html|
        html.gsub(/<img\b[^>]*\bsrc="([^"]+)"[^>]*>/) do |full_tag|
          gh_url = ::Regexp.last_match(1)
          next full_tag unless gh_url.match?(GH_IMAGE_HOST_RE)

          plane_path = cache[gh_url]
          if plane_path.nil?
            plane_path = Attachments.mirror_one_image(
              plane, github, project_id, work_item_id, gh_url,
              log: log, apply: apply
            )
            cache[gh_url] = plane_path
          end

          next full_tag if plane_path.nil? # download/upload failed; leave original

          new_src = "#{plane.base_url}#{plane_path}"
          full_tag.sub(/\bsrc="[^"]+"/, "src=\"#{new_src}\"")
        end
      end
    end

    # Build asset_url string from an attachment record (the API returns
    # `asset_url` on creation but only `asset` on list). They're equivalent
    # in practice; we synthesise one for cache-hit matching.
    def self.asset_url_for(slug, att)
      "/api/assets/v2/workspaces/#{att['workspace'] && slug}/projects/#{att['project']}/" \
        "issues/#{att['issue']}/attachments/#{att['id']}/"
    end
  end
end
