# frozen_string_literal: true

module PlaneTools
  # Pre-pass on a GitHub comment's markdown body that turns bare
  # cross-references into explicit Markdown hyperlinks. Rewrites:
  #
  #   #123                  -> [#123](https://github.com/<own-repo>/issues/123)
  #   owner/repo#123        -> [owner/repo#123](https://github.com/owner/repo/issues/123)
  #
  # When a `plane_index` is supplied AND the resolved (repo, number)
  # has a Plane sibling, the rewriter appends a second hyperlink:
  #
  #   #123  ->  [#123](github-url) ([D4D-49](plane-url))
  #
  # GitHub auto-redirects /issues/N to /pull/N when N is a PR, so we
  # don't need to know the type to produce a working GH link.
  #
  # The rewriter is intentionally conservative: text inside fenced
  # code blocks (``` / ~~~), inline code spans (`...` and ``...``),
  # and existing Markdown link constructs (`[text](url)`) are left
  # untouched. Anything else in prose is fair game.
  module CrossRefLinker
    # Block-fence: ``` or ~~~ on its own (possibly after attrs).
    FENCE_RE = /^[ \t]{0,3}(?<fence>```+|~~~+)[^\n]*$/.freeze

    # Inline code span: a run of N backticks, then anything, then
    # the same run, with no internal triple backticks. Greedy enough
    # for ordinary usage; pathological cases fall through unharmed.
    INLINE_CODE_RE = /(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)/m.freeze

    # Markdown link `[text](url)`. We skip the whole construct
    # verbatim: a link the human (or upstream tooling) explicitly
    # wrote is their choice — appending or rewriting anything after
    # it would be presumptuous, easy to get wrong (comment-anchored
    # URLs, self-referential links to the work item being rendered,
    # sub-path URLs like /pull/N/files etc.), and was the source of
    # a real bug where each comment's body-header self-quote ended
    # up duplicated with a spurious Plane-id appended.
    MD_LINK_RE = /\[(?:[^\[\]]|\\\[|\\\])*\]\((?:[^()]|\([^()]*\))*\)/m.freeze

    # owner/repo: alphanumeric + `.` `_` `-` segments, one slash.
    REPO_SEGMENT = /[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/.freeze
    REPO_NAME    = /[A-Za-z0-9][A-Za-z0-9._-]*/.freeze
    CROSS_REPO_RE = %r{(?<![A-Za-z0-9._/-])(#{REPO_SEGMENT}/#{REPO_NAME})\#(\d+)\b}.freeze

    # Bare `#N`: must not be preceded by an alphanumeric, slash, or
    # another hash, and must not be the start of a `#L42`-style
    # line anchor.
    BARE_REF_RE = /(?<![A-Za-z0-9._\/#])\#(\d+)\b/.freeze

    GITHUB_BASE = "https://github.com"
    DEFAULT_PLANE_WEB_BASE = "https://app.plane.so"

    module_function

    # Rewrite cross-references in `markdown`.
    #
    # Required:
    #   repo:         the work item's own GH repo, used to resolve
    #                 bare `#N` (e.g. "forwarddemocracy/data4democracy")
    #
    # Optional (all must be provided together for phase-2 dual-link):
    #   plane_index:  Hash keyed by "repo#N", values are hashes
    #                 with :project_identifier, :sequence_id, :slug
    #   plane_web_base: default "https://app.plane.so"
    #   logger:       Logger-like object; receives `.debug` calls
    #                 for refs with no Plane sibling
    def rewrite(markdown, repo:, plane_index: nil, plane_web_base: DEFAULT_PLANE_WEB_BASE, logger: nil)
      return markdown if markdown.nil? || markdown.empty?

      ctx = { repo: repo, index: plane_index, plane_web_base: plane_web_base, logger: logger }
      walk_fences(markdown) { |chunk| rewrite_prose_chunk(chunk, ctx) }
    end

    # Split on fenced code blocks. Yields each prose chunk to the
    # block for rewriting; fenced blocks pass through verbatim.
    def walk_fences(markdown)
      out = +""
      buf = +""
      in_fence = false
      fence_marker = nil
      markdown.each_line do |line|
        if in_fence
          buf << line
          if line.match?(/^[ \t]{0,3}#{Regexp.escape(fence_marker)}[ \t]*\r?\n?$/)
            out << buf
            buf = +""
            in_fence = false
            fence_marker = nil
          end
        elsif (m = line.match(FENCE_RE))
          out << yield(buf) unless buf.empty?
          buf = +line
          in_fence = true
          fence_marker = m[:fence]
        else
          buf << line
        end
      end
      out << (in_fence ? buf : yield(buf)) unless buf.empty?
      out
    end

    # Rewrite a chunk of prose markdown (already known to be
    # outside any fenced code block). Inline code spans and
    # existing markdown-link constructs (`[text](url)`) are
    # preserved verbatim. Bare and cross-repo `#N` refs in the
    # remaining prose are hyperlinked.
    def rewrite_prose_chunk(text, ctx)
      protect(text, [INLINE_CODE_RE, MD_LINK_RE]) do |prose|
        prose
          .gsub(CROSS_REPO_RE) do
            cross_repo = ::Regexp.last_match(1)
            num = ::Regexp.last_match(2)
            build_links("#{cross_repo}##{num}", cross_repo, num, ctx)
          end
          .gsub(BARE_REF_RE) do
            num = ::Regexp.last_match(1)
            build_links("##{num}", ctx[:repo], num, ctx)
          end
      end
    end

    # Apply `block` only to the bits of `text` outside any of the
    # `regexes`. Matched regions are appended verbatim.
    def protect(text, regexes)
      combined = Regexp.union(regexes)
      out = +""
      pos = 0
      while (m = combined.match(text, pos))
        out << yield(text[pos...m.begin(0)])
        out << m[0]
        pos = m.end(0)
      end
      out << yield(text[pos..])
      out
    end

    def build_links(visible, repo, number, ctx)
      gh = gh_link(visible, repo, number)
      sibling = lookup_sibling(repo, number, ctx)
      return gh unless sibling

      "#{gh} (#{plane_link(sibling, ctx[:plane_web_base])})"
    end

    def gh_link(visible, repo, number)
      "[#{visible}](#{GITHUB_BASE}/#{repo}/issues/#{number})"
    end

    def plane_link(sibling, plane_web_base)
      id = "#{sibling[:project_identifier]}-#{sibling[:sequence_id]}"
      "[#{id}](#{plane_web_base}/#{sibling[:slug]}/browse/#{id})"
    end

    def lookup_sibling(repo, number, ctx)
      index = ctx[:index]
      return nil unless index

      key = "#{repo}##{number}"
      sibling = index[key]
      if sibling.nil?
        ctx[:logger]&.debug("    no Plane sibling for #{key}")
        return nil
      end
      sibling
    end
  end
end
