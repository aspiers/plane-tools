# frozen_string_literal: true

RSpec.describe PlaneTools::CrossRefLinker do
  let(:repo) { "forwarddemocracy/data4democracy" }

  def rewrite(md) = described_class.rewrite(md, repo: repo)

  describe "bare #N refs" do
    it "links a single bare ref" do
      expect(rewrite("see #123 for details")).to eq(
        "see [#123](https://github.com/forwarddemocracy/data4democracy/issues/123) for details"
      )
    end

    it "links multiple bare refs in one line" do
      expect(rewrite("blocked by #1 and #22"))
        .to include("[#1](https://github.com/forwarddemocracy/data4democracy/issues/1)")
        .and include("[#22](https://github.com/forwarddemocracy/data4democracy/issues/22)")
    end

    it "leaves a trailing # alone" do
      expect(rewrite("hash # without number")).to eq("hash # without number")
    end

    it "does not match inside identifiers" do
      expect(rewrite("foo#123bar abc#9")).to eq("foo#123bar abc#9")
    end

    it "does not match URL fragments like #L42" do
      expect(rewrite("see file.rb#L42")).to eq("see file.rb#L42")
    end

    it "does not match Markdown headings (##)" do
      expect(rewrite("## section\nthen ##1 not a ref")).to eq("## section\nthen ##1 not a ref")
    end

    it "matches at start of string" do
      expect(rewrite("#42 first")).to eq(
        "[#42](https://github.com/forwarddemocracy/data4democracy/issues/42) first"
      )
    end

    it "matches at end of string" do
      expect(rewrite("ends with #99")).to eq(
        "ends with [#99](https://github.com/forwarddemocracy/data4democracy/issues/99)"
      )
    end

    it "matches inside parenthesised prose" do
      expect(rewrite("(see #7)")).to eq(
        "(see [#7](https://github.com/forwarddemocracy/data4democracy/issues/7))"
      )
    end
  end

  describe "cross-repo owner/repo#N refs" do
    it "links a cross-repo ref to that repo" do
      expect(rewrite("see forwarddemocracy/tacticalvote#456")).to eq(
        "see [forwarddemocracy/tacticalvote#456]" \
        "(https://github.com/forwarddemocracy/tacticalvote/issues/456)"
      )
    end

    it "handles repo names with dots / dashes / underscores" do
      expect(rewrite("track owner-name/repo.with_chars#7")).to eq(
        "track [owner-name/repo.with_chars#7]" \
        "(https://github.com/owner-name/repo.with_chars/issues/7)"
      )
    end

    it "does not double-match a cross-repo ref as bare" do
      result = rewrite("see foo/bar#9")
      expect(result.scan(/\[/).size).to eq(1)
      expect(result).to eq("see [foo/bar#9](https://github.com/foo/bar/issues/9)")
    end
  end

  describe "code-region exemption" do
    it "leaves bare refs inside inline code spans alone" do
      expect(rewrite("touch `#123` not")).to eq("touch `#123` not")
    end

    it "leaves cross-repo refs inside inline code spans alone" do
      expect(rewrite("look at `foo/bar#42`")).to eq("look at `foo/bar#42`")
    end

    it "leaves refs inside fenced code blocks alone" do
      input = <<~MD
        before #1
        ```
        a literal #2 here
        ```
        after #3
      MD
      out = rewrite(input)
      expect(out).to include("[#1](")
      expect(out).to include("[#3](")
      expect(out).to include("a literal #2 here")
      expect(out).not_to include("[#2](")
    end

    it "leaves refs inside ~~~-fenced blocks alone" do
      input = "see #1\n~~~\nliteral #2\n~~~\nand #3\n"
      out = rewrite(input)
      expect(out).to include("[#1](")
      expect(out).to include("[#3](")
      expect(out).not_to include("[#2](")
    end

    it "rewrites refs immediately after a closed fence" do
      input = "```\nin #1\n```\nout #2\n"
      out = rewrite(input)
      expect(out).not_to include("[#1](")
      expect(out).to include("[#2](")
    end

    it "leaves refs inside double-backtick code spans alone" do
      expect(rewrite("look at ``#42 here``")).to eq("look at ``#42 here``")
    end
  end

  describe "existing markdown links" do
    it "does not rewrite #N inside the text of an existing link" do
      input = "see [#9 details](https://example.com)"
      expect(rewrite(input)).to eq(input)
    end

    it "does not nest brackets when the linked text is exactly #N" do
      input = "[#10](https://example.com)"
      expect(rewrite(input)).to eq(input)
    end

    it "still rewrites refs OUTSIDE existing links on the same line" do
      input = "see [#9](https://example.com) but also #10"
      out = rewrite(input)
      expect(out).to include("[#9](https://example.com)")
      expect(out).to include("[#10](https://github.com/forwarddemocracy/data4democracy/issues/10)")
    end
  end

  describe "phase-2 dual-link with plane_index" do
    let(:index) do
      {
        "forwarddemocracy/data4democracy#159" => {
          project_identifier: "D4D", sequence_id: 75, slug: "fwddem"
        },
        "forwarddemocracy/tacticalvote#495" => {
          project_identifier: "TV", sequence_id: 40, slug: "fwddem"
        }
      }
    end

    def rewrite_p2(md, **extra)
      described_class.rewrite(md, repo: repo, plane_index: index, **extra)
    end

    it "appends a Plane sibling link when bare ref has a match" do
      out = rewrite_p2("see #159 for context")
      expect(out).to eq(
        "see [#159](https://github.com/forwarddemocracy/data4democracy/issues/159)" \
        " ([D4D-75](https://app.plane.so/fwddem/browse/D4D-75)) for context"
      )
    end

    it "appends a Plane sibling link when cross-repo ref has a match" do
      out = rewrite_p2("blocked by forwarddemocracy/tacticalvote#495")
      expect(out).to eq(
        "blocked by [forwarddemocracy/tacticalvote#495]" \
        "(https://github.com/forwarddemocracy/tacticalvote/issues/495)" \
        " ([TV-40](https://app.plane.so/fwddem/browse/TV-40))"
      )
    end

    it "falls back to single GH link when bare ref has no Plane sibling" do
      out = rewrite_p2("ancient #99 left as-is")
      expect(out).to eq(
        "ancient [#99](https://github.com/forwarddemocracy/data4democracy/issues/99) left as-is"
      )
    end

    it "logs a debug note for unmatched refs when a logger is supplied" do
      logger = double("logger")
      expect(logger).to receive(:debug).with(/no Plane sibling for forwarddemocracy\/data4democracy#99/)
      rewrite_p2("ancient #99", logger: logger)
    end

    it "does not log unmatched refs when no logger is supplied" do
      expect { rewrite_p2("ancient #99") }.not_to raise_error
    end

    it "honours a custom plane_web_base" do
      out = described_class.rewrite(
        "see #159", repo: repo, plane_index: index,
        plane_web_base: "https://plane.example.com"
      )
      expect(out).to include("(https://plane.example.com/fwddem/browse/D4D-75)")
    end

    it "is still idempotent in phase-2 mode" do
      once = rewrite_p2("see #159 and #99 and foo/bar#7")
      expect(rewrite_p2(once)).to eq(once)
    end

    describe "respect for existing markdown links" do
      it "leaves a [text](github-issue-url) construct alone in phase-2 mode" do
        input = "see [#159 details](https://github.com/forwarddemocracy/data4democracy/issues/159)"
        expect(rewrite_p2(input)).to eq(input)
      end

      it "leaves a [text](github-comment-anchor) construct alone" do
        input = "see [author wrote on GitHub]" \
                "(https://github.com/forwarddemocracy/data4democracy/issues/159#issuecomment-4408408032)"
        expect(rewrite_p2(input)).to eq(input)
      end

      it "leaves a [text](github-pull-subpath) construct alone" do
        input = "[diff](https://github.com/forwarddemocracy/data4democracy/pull/159/files)"
        expect(rewrite_p2(input)).to eq(input)
      end
    end
  end

  describe "edge cases" do
    it "leaves empty string alone" do
      expect(rewrite("")).to eq("")
    end

    it "leaves nil input alone" do
      expect(described_class.rewrite(nil, repo: repo)).to be_nil
    end

    it "preserves trailing newline" do
      expect(rewrite("see #1\n")).to eq(
        "see [#1](https://github.com/forwarddemocracy/data4democracy/issues/1)\n"
      )
    end

    it "handles mixed bare and cross-repo on one line" do
      out = rewrite("see #1 and foo/bar#2 and #3")
      expect(out).to include("[#1](https://github.com/forwarddemocracy/data4democracy/issues/1)")
      expect(out).to include("[foo/bar#2](https://github.com/foo/bar/issues/2)")
      expect(out).to include("[#3](https://github.com/forwarddemocracy/data4democracy/issues/3)")
    end

    it "is idempotent: re-running on already-rewritten output is a no-op" do
      once = rewrite("see #5 and foo/bar#6")
      expect(rewrite(once)).to eq(once)
    end
  end
end
