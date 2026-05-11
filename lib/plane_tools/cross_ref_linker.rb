# frozen_string_literal: true

module PlaneTools
  # Pre-pass on a GitHub comment's markdown body that turns bare
  # cross-references into explicit Markdown hyperlinks. Rewrites:
  #
  #   #123                  -> [#123](https://github.com/<own-repo>/issues/123)
  #   owner/repo#123        -> [owner/repo#123](https://github.com/owner/repo/issues/123)
  #
  # GitHub auto-redirects /issues/N to /pull/N when N is a PR, so we
  # don't need to know the type to produce a working link.
  #
  # The rewriter is intentionally conservative: text inside fenced
  # code blocks (``` / ~~~), inline code spans (`...` and ``...``),
  # and the visible-text part of an existing Markdown link
  # (`[...](...)`) is left untouched. Anything else in prose is
  # fair game.
  module CrossRefLinker
    # Block-fence: ``` or ~~~ on its own (possibly after attrs).
    FENCE_RE = /^[ \t]{0,3}(?<fence>```+|~~~+)[^\n]*$/.freeze

    # Inline code span: a run of N backticks, then anything, then
    # the same run, with no internal triple backticks. Greedy enough
    # for ordinary usage; pathological cases fall through unharmed.
    INLINE_CODE_RE = /(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)/m.freeze

    # Markdown link `[text](url)` or `[text][ref]`. We skip the
    # whole construct (text + url) — the link already targets
    # something explicit and rewriting visible-text inside it
    # produces nested-bracket garbage.
    MD_LINK_RE = /\[(?:[^\[\]]|\\\[|\\\])*\]\((?:[^()]|\([^()]*\))*\)/m.freeze

    # owner/repo: alphanumeric + `.` `_` `-` segments, one slash.
    REPO_SEGMENT = /[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/.freeze
    REPO_NAME    = /[A-Za-z0-9][A-Za-z0-9._-]*/.freeze
    CROSS_REPO_RE = %r{(?<![A-Za-z0-9._/-])(#{REPO_SEGMENT}/#{REPO_NAME})\#(\d+)\b}.freeze

    # Bare `#N`: must not be preceded by an alphanumeric, slash, or
    # another hash. The trailing `(?!L\d)` skips `#L42` line anchors
    # commonly seen in code URLs.
    BARE_REF_RE = /(?<![A-Za-z0-9._\/#])\#(\d+)\b/.freeze

    GITHUB_BASE = "https://github.com"

    module_function

    # Rewrite cross-references in `markdown`, resolving bare `#N`
    # against `repo` (e.g. "forwarddemocracy/data4democracy").
    # Returns the rewritten markdown.
    def rewrite(markdown, repo:)
      return markdown if markdown.nil? || markdown.empty?

      walk_fences(markdown) { |chunk| rewrite_prose_chunk(chunk, repo) }
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
    # markdown-link constructs are still preserved verbatim.
    def rewrite_prose_chunk(text, repo)
      protect(text, [INLINE_CODE_RE, MD_LINK_RE]) do |prose|
        prose
          .gsub(CROSS_REPO_RE) do
            link("#{::Regexp.last_match(1)}##{::Regexp.last_match(2)}",
                 ::Regexp.last_match(1), ::Regexp.last_match(2))
          end
          .gsub(BARE_REF_RE) do
            link("##{::Regexp.last_match(1)}", repo, ::Regexp.last_match(1))
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

    def link(visible, repo, number)
      "[#{visible}](#{GITHUB_BASE}/#{repo}/issues/#{number})"
    end
  end
end
