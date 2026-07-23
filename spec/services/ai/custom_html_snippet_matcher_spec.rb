# frozen_string_literal: true

require "spec_helper"

describe Ai::CustomHtmlSnippetMatcher do
  describe ".match" do
    it "prefers the exact match when the snippet appears verbatim" do
      result = described_class.match("<p>hello world</p>", "hello world")

      expect(result.occurrences).to eq(1)
      expect(result.matcher).to eq("hello world")
    end

    it "reports exact multi-matches as ambiguous without falling back to tolerant matching" do
      # Two exact occurrences must surface as 2 — falling back could otherwise mask the ambiguity.
      result = described_class.match("<p>buy</p><p>buy</p>", "<p>buy</p>")

      expect(result.occurrences).to eq(2)
    end

    it "matches a snippet whose plain space stands in for the page's non-breaking space" do
      # The gumroad-private#1251 shape: the stored page has U+00A0 inside the cursor span, the
      # agent echoed the snippet back with an ASCII space, and exact matching found nothing.
      page = "<h1 class=\"headline\">What habits?<span class=\"cursor\">\u00A0</span>\n</h1>"
      find = "<h1 class=\"headline\">What habits?<span class=\"cursor\"> </span>\n</h1>"

      result = described_class.match(page, find)

      expect(result.occurrences).to eq(1)
      expect(page.sub(result.matcher) { "replaced" }).to eq("replaced")
    end

    it "matches in the other direction too (snippet has the NBSP, page has a plain space)" do
      result = described_class.match("<p>a b</p>", "<p>a\u00A0b</p>")

      expect(result.occurrences).to eq(1)
    end

    it "treats an &nbsp; entity in the page as whitespace" do
      result = described_class.match("<p>a&nbsp;b</p>", "<p>a b</p>")

      expect(result.occurrences).to eq(1)
    end

    it "matches across differing whitespace runs (newline and indentation vs a single space)" do
      result = described_class.match("<div>\n  <p>hi</p>\n</div>", "<div> <p>hi</p> </div>")

      expect(result.occurrences).to eq(1)
    end

    it "does not invent a match where non-whitespace content differs" do
      result = described_class.match("<p>hello world</p>", "<p>goodbye world</p>")

      expect(result.occurrences).to eq(0)
    end

    it "keeps the snippet literal — regex metacharacters in it never act as a pattern" do
      page = "<p>Price: $10 (sale). Also literally $1X (sale)</p>"

      result = described_class.match(page, "$10 (sale)")

      expect(result.occurrences).to eq(1)
      expect(page.sub(result.matcher) { "$8 (sale)" }).to include("$8 (sale)")
      expect(page).to include("$1X (sale)")
    end

    it "requires whitespace to be present on both sides — a space in the snippet never matches nothing" do
      # Tolerant matching generalizes whitespace runs, it does not make them optional: "a b"
      # must not match a page containing "ab".
      result = described_class.match("<p>ab</p>", "<p>a b</p>")

      expect(result.occurrences).to eq(0)
    end

    it "prefers a unique exact occurrence even when a whitespace-variant of it also exists" do
      # The exact pass matches the plain-space paragraph alone, so the edit stays unambiguous —
      # the NBSP variant is only considered when nothing matches exactly.
      page = "<p>a\u00A0b</p><p>a b</p>"

      result = described_class.match(page, "<p>a b</p>")

      expect(result.occurrences).to eq(1)
      expect(page.sub(result.matcher) { "X" }).to eq("<p>a\u00A0b</p>X")
    end

    it "counts tolerant multi-matches as ambiguous" do
      result = described_class.match("<p>a\u00A0b</p><p>a\u00A0b</p>", "<p>a b</p>")

      expect(result.occurrences).to eq(2)
    end

    it "replaces exactly the tolerant match, leaving the rest of the page untouched" do
      page = "<section><h1>Hi\u00A0there</h1><p>keep me</p></section>"

      result = described_class.match(page, "<h1>Hi there</h1>")
      edited = page.sub(result.matcher) { "<h1>New</h1>" }

      expect(edited).to eq("<section><h1>New</h1><p>keep me</p></section>")
    end
  end
end
