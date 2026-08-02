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
      source[/<strong>#{sp}*A#{sp}+note#{sp}+on#{sp}+fortune#{sp}+tellers\.#{sp}*<\/strong>.*?(?=<p><strong>|<\/div>)/om]
    end

    # Without this the two include examples below would fail on nil rather than on their subject,
    # which reads as a broken spec instead of a missing note.
    it "slices a note out of the page" do
      expect(note).to_not be_nil
    end

    it "is reachable from item 28" do
      expect(source).to include("<li>fortune tellers. See the note on fortune tellers below.</li>")
    end

    # The seller-visible point of the note: the categories we ship in Discover are named as allowed.
    it "names the allowed traditions" do
      expect(note).to include("astrology", "tarot", "divination")
    end

    # A bare slug is NOT a Discover URL — DiscoverTaxonomyConstraint matches the full ancestry path
    # only, so gumroad.com/tarot falls through to the username subdomain and lands on whichever
    # creator owns that handle. The link must be generated from the route helper for that reason.
    it "links the tarot category by its full ancestry path" do
      expect(note).to include(%(discover_taxonomy_url("self-improvement/spirituality/mysticism/tarot", host: DISCOVER_DOMAIN)))
    end

    it "states what remains prohibited" do
      expect(note).to include("prediction service")
    end
  end

  # Guards the example above. The test DB has no taxonomy rows, so this reads the ancestry out of
  # the seed file that defines production's tree instead: a re-parent of tarot reddens here rather
  # than shipping another link to whichever creator owns the bare slug.
  it "pins the tarot ancestry the taxonomy seeds define" do
    seeds = Rails.root.join("db/seeds/010_development_staging_test/taxonomy_create.rb").read
    parent_of = seeds.scan(/find_or_create_by!\(slug: "([^"]+)"(?:, parent: (\w+))?\)/).to_h
    var_slug = seeds.scan(/^(\w+) = Taxonomy\.find_or_create_by!\(slug: "([^"]+)"/).to_h

    ancestry = ->(slug) do
      path = [slug]
      path.unshift(var_slug.fetch(parent_of.fetch(path.first))) while parent_of[path.first]
      path
    end

    expect(ancestry.call("tarot")).to eq(%w[self-improvement spirituality mysticism tarot])
  end
end
