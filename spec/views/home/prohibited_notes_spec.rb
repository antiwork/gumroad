# frozen_string_literal: true

require "spec_helper"

# The prohibited list carries bare category names, so a category we actually operate a Discover
# section for (tarot/astrology under item 28) reads as a flat ban. The fix is a clarifying note, and
# a note is only reachable if the list item points at it — so this asserts the pointer and the note
# stay paired in both directions rather than pinning either one's wording. gumroad-private#1713.
#
# [[:space:]] rather than \s throughout: \s does not match U+00A0, so an nbsp creeping into this
# hand-maintained markup would make a \s gap silently skip the row and pass.
describe "app/views/home/prohibited.html.erb clarifying notes" do
  def sp
    "[[:space:]]"
  end

  let(:source) { Rails.root.join("app/views/home/prohibited.html.erb").read }

  # "<li>gambling (...). See the note on gambling below.</li>" => "gambling"
  let(:pointers) do
    source.scan(/See#{sp}+the#{sp}+note#{sp}+on#{sp}+([^<.]+?)#{sp}+below\./o).flatten.map(&:strip)
  end

  # "<p><strong>A note on gambling.</strong>" => "gambling"
  let(:notes) do
    source.scan(/<strong>#{sp}*A#{sp}+note#{sp}+on#{sp}+([^<.]+?)\.#{sp}*<\/strong>/o).flatten.map(&:strip)
  end

  it "pairs every pointer with a note and every note with a pointer" do
    expect(pointers).to match_array(notes)
  end

  # Guards the two scans above against a regex that stops matching: with both scanning zero, the
  # pairing assertion is [] == [] and passes over a page with no notes at all.
  it "finds both maintained notes" do
    expect(notes).to match_array(["fortune tellers", "gambling"])
  end

  describe "the fortune teller note" do
    let(:note) do
      source[/<strong>#{sp}*A#{sp}+note#{sp}+on#{sp}+fortune#{sp}+tellers\.#{sp}*<\/strong>.*?(?=<p>#{sp}*<strong>|<\/div>)/om]
    end

    # Without this the two include examples below would fail on nil rather than on their subject,
    # which reads as a broken spec instead of a missing note.
    it "slices a note out of the page" do
      expect(note).to_not be_nil
    end

    it "is reachable from its list entry" do
      expect(source).to include("<li>fortune tellers. See the note on fortune tellers below.</li>")
    end

    # The seller-visible point of the note: the categories we ship in Discover are named as allowed.
    # "tarot" alone would also be satisfied by the Discover URL inside the slice, so this asserts
    # prose-only words too.
    it "names the allowed traditions" do
      expect(note).to include("astrology", "tarot", "divination", "numerology", "birth-chart")
    end

    # Guards the slice's lookahead: a widened slice would swallow the next note and every include
    # above would still pass, so "in the fortune-teller note" would stop meaning anything.
    it "stops before the gambling note" do
      expect(note).to_not include("A note on gambling")
    end

    it "states what remains prohibited" do
      expect(note).to include("prediction service")
    end
  end

  # The source scans above cannot see the link: they would stay green if the route helper were
  # renamed away (page 500s), if `<%=` became `<%` (link silently vanishes), or if DISCOVER_DOMAIN
  # left view scope. Only rendered output settles whether a reader can click through.
  describe "the rendered Discover link" do
    # A bare slug is NOT a Discover URL — DiscoverTaxonomyConstraint matches the full ancestry path
    # only, so gumroad.com/tarot falls through to the username route and lands on whichever creator
    # owns that handle. Building the path from the tree keeps the page honest if tarot is reparented.
    let(:tarot_path) do
      self_improvement = Taxonomy.find_or_create_by!(slug: "self-improvement")
      spirituality = Taxonomy.find_or_create_by!(slug: "spirituality", parent: self_improvement)
      mysticism = Taxonomy.find_or_create_by!(slug: "mysticism", parent: spirituality)
      tarot = Taxonomy.find_or_create_by!(slug: "tarot", parent: mysticism)
      tarot.self_and_ancestors.reverse.map(&:slug).join("/")
    end

    let(:rendered) { ApplicationController.render(template: "home/prohibited", layout: false) }

    it "points at the tarot category's full ancestry path" do
      expect(tarot_path).to eq("self-improvement/spirituality/mysticism/tarot")
      expect(rendered).to include(%(href="#{UrlService.discover_domain_with_protocol}/#{tarot_path}"))
    end
  end
end
