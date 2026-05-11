# frozen_string_literal: true

module PlaneTools
  # Renders a GitHub comment's markdown body to Plane-safe HTML.
  #
  # Responsibilities:
  #  - Run Commonmarker with GFM options matching github.com's
  #    server-side renderer.
  #  - Collapse whitespace that Plane's editor would otherwise
  #    render literally as phantom paragraphs / line breaks.
  #  - Inject explicit `colwidth=` attrs onto every <th>/<td> so
  #    Plane's TipTap table extension lays the table out sensibly
  #    instead of pinning every column to 150px.
  #  - Wrap an image-rewriter callable around the result so
  #    GH-hosted image URLs become Plane attachment URLs.
  class GhRenderer
    # GFM-flavoured options matching GitHub's server-side renderer.
    # `header_ids: nil` suppresses the auto-generated <a id=...> anchors on
    # headings (Plane has no use for them and they pollute the rendering).
    # `hardbreaks: true` mirrors GitHub's renderer: a single `\n` inside a
    # paragraph becomes <br> rather than collapsing to a space. This
    # matches what users see on github.com (and our collapse_whitespace
    # pass leaves explicit <br> tags alone).
    COMMONMARKER_OPTS = {
      parse: { smart: false },
      render: { hardbreaks: true, github_pre_lang: true, unsafe: true },
      extension: { header_ids: nil }
    }.freeze
    COMMONMARKER_PLUGINS = {
      syntax_highlighter: nil
    }.freeze

    # Plane's TipTap table extension respects `colwidth` attrs on each
    # <th>/<td>. Without them, tables default to 150px/col which is wrong
    # in both directions (too wide for short data, too narrow for prose).
    # Per col we compute:
    #  - natural = max(cell_text_length) * PX_PER_CHAR + PADDING
    #  - min    = max(longest_unbreakable_token) * PX_PER_CHAR + PADDING
    # If sum(natural) <= target, use naturals (compact, no wrap, fits).
    # Else distribute target: every col gets at least its min; remaining
    # (target - sum(min)) distributed proportionally to slack (natural -
    # min) across cols. Short data cols ("1.000", "Cov") have min ≈ natural
    # so they don't shrink past readability; prose cols absorb shrinkage.
    TABLE_TARGET_WIDTH    = 756
    TABLE_PX_PER_CHAR     = 8
    TABLE_CELL_PADDING    = 24 # left+right padding/border per cell
    TABLE_BOLD_FACTOR     = 1.15 # <strong> chars wider than regular
    TABLE_CODE_FACTOR     = 1.10 # monospace <code> chars wider than regular
    TABLE_CODE_CHIP_PAD   = 12 # extra px for the <code> rounded chip styling

    def self.render(gh_comment, image_rewriter:, repo:,
                    gh_to_plane_index: nil, plane_web_base: nil, logger: nil)
      new.render(
        gh_comment, image_rewriter: image_rewriter, repo: repo,
        gh_to_plane_index: gh_to_plane_index,
        plane_web_base: plane_web_base, logger: logger
      )
    end

    def render(gh_comment, image_rewriter:, repo:,
               gh_to_plane_index: nil, plane_web_base: nil, logger: nil)
      ts = gh_comment.created_at.strftime("%Y-%m-%d %H:%M UTC")
      # Note: clicking this link in Plane currently opens two browser
      # tabs - reproducible even on links authored inside Plane's own
      # editor, regardless of target/rel/class attributes. Plane bug;
      # accepting it here because two tabs beats no link at all.
      header = "<p><a href=\"#{gh_comment.html_url}\">" \
               "<em>#{gh_comment.user.login} wrote on GitHub on #{ts}</em>" \
               "</a></p>"
      cross_ref_args = { repo: repo, plane_index: gh_to_plane_index, logger: logger }
      cross_ref_args[:plane_web_base] = plane_web_base if plane_web_base
      body_md = CrossRefLinker.rewrite(gh_comment.body.to_s, **cross_ref_args)
      rendered = Commonmarker.to_html(
        body_md, options: COMMONMARKER_OPTS, plugins: COMMONMARKER_PLUGINS
      ).strip
      rewritten = image_rewriter.call(rendered)
      with_widths = add_table_colwidths(rewritten)
      collapse_whitespace(header + with_widths)
    end

    # Plane's editor renders any whitespace it sees in our HTML literally:
    # `\n` between tags becomes a phantom blank paragraph, `\n` inside text
    # becomes a forced line break. Collapse all runs of whitespace to a
    # single space EXCEPT inside <pre>...</pre> where line breaks matter.
    def collapse_whitespace(html)
      parts = html.split(%r{(<pre[^>]*>.*?</pre>)}m)
      parts.each_with_index do |part, i|
        next if i.odd? # odd indices are the <pre>...</pre> blocks; preserve verbatim

        # Collapse runs of whitespace (including \n) to a single space, then
        # remove that space where it sits between adjacent tags. Also strip
        # whitespace immediately after a <br> tag — Commonmarker emits
        # `<br />\n<text>` which would otherwise leave a leading space on
        # the line after each hard-break.
        parts[i] = part.gsub(/\s+/, " ").gsub(/>\s+</, "><").gsub(%r{(<br\s*/?>)\s+}, '\1')
      end
      parts.join
    end

    # Walk a cell's HTML, yielding one entry per (text-fragment) as
    # {chars:, longest_token:, px_per_char:, chip_pad:}. Tracks active
    # bold/code formatting depth so multipliers apply correctly.
    def cell_fragments(cell_html)
      parts = cell_html.split(/(<[^>]+>)/)
      bold_depth = 0
      code_depth = 0
      out = []
      parts.each do |p|
        if p.start_with?("<")
          tag = p[1..].sub(%r{^/}, "").split(/\s|>/).first&.downcase
          next unless tag

          delta = p.start_with?("</") ? -1 : (p.end_with?("/>") ? 0 : +1)
          bold_depth += delta if %w[strong b].include?(tag)
          code_depth += delta if %w[code].include?(tag)
        else
          text = p.gsub(/\s+/, " ")
          next if text.strip.empty?

          mult = 1.0
          mult *= TABLE_BOLD_FACTOR if bold_depth.positive?
          mult *= TABLE_CODE_FACTOR if code_depth.positive?
          out << {
            chars: text.length,
            longest_token: text.split(/\s+/).map(&:length).max || 0,
            px_per_char: TABLE_PX_PER_CHAR * mult,
            chip_pad: code_depth.positive? ? TABLE_CODE_CHIP_PAD : 0
          }
        end
      end
      out
    end

    # Sum effective px of all cell content (natural, single-line width).
    def cell_natural_px(cell_html)
      cell_fragments(cell_html).sum { |f| f[:chars] * f[:px_per_char] + f[:chip_pad] }
    end

    # Max effective px of any single unbreakable token in the cell.
    # This is what the col cannot shrink below without forcing mid-word wrap.
    def cell_min_px(cell_html)
      cell_fragments(cell_html).map { |f| f[:longest_token] * f[:px_per_char] + f[:chip_pad] }.max || 0
    end

    def add_table_colwidths(html)
      html.gsub(%r{<table\b[^>]*>.*?</table>}m) do |table|
        rows = table.scan(%r{<tr\b[^>]*>.*?</tr>}m)
        next table if rows.empty?

        cells_per_row = rows.map { |row| row.scan(%r{<(?:th|td)\b[^>]*>.*?</(?:th|td)>}m) }
        num_cols = cells_per_row.map(&:size).max
        next table if num_cols.nil? || num_cols.zero?

        widths = compute_widths(cells_per_row, num_cols)
        inject_widths(table, widths)
      end
    end

    private

    def compute_widths(cells_per_row, num_cols)
      # Per col: max effective px (natural) and max effective token px (min).
      max_natural_px = Array.new(num_cols, 0.0)
      max_token_px = Array.new(num_cols, 0.0)
      cells_per_row.each do |row_cells|
        row_cells.each_with_index do |cell, ci|
          nat = cell_natural_px(cell)
          tok = cell_min_px(cell)
          max_natural_px[ci] = nat if nat > max_natural_px[ci]
          max_token_px[ci] = tok if tok > max_token_px[ci]
        end
      end

      natural = max_natural_px.map { |px| px.ceil + TABLE_CELL_PADDING }
      min_w = max_token_px.map { |px| px.ceil + TABLE_CELL_PADDING }
      return natural if natural.sum <= TABLE_TARGET_WIDTH

      # Distribute target: floor each at min, share leftover by slack.
      leftover = TABLE_TARGET_WIDTH - min_w.sum
      return min_w if leftover <= 0 # all cols pinned to min; best we can do

      slack = natural.zip(min_w).map { |n, m| n - m }
      total_slack = slack.sum
      return min_w if total_slack.zero?

      min_w.zip(slack).map { |m, s| m + (s * leftover / total_slack.to_f).floor }
    end

    def inject_widths(table, widths)
      # Inject colwidth="N" per cell, processing row by row so column
      # index is correct even if a row has fewer cells than `num_cols`.
      table.gsub(%r{<tr\b[^>]*>.*?</tr>}m) do |row|
        ci = -1
        row.gsub(%r{<((?:th|td))\b([^>]*)>}) do
          tag = ::Regexp.last_match(1)
          attrs = ::Regexp.last_match(2).gsub(/\s*\bcolwidth="\d+"/, "")
          ci += 1
          w = widths[ci] || widths.last
          "<#{tag}#{attrs} colwidth=\"#{w}\">"
        end
      end
    end
  end
end
