# frozen_string_literal: true

require "spec_helper"

# A clarifying note is only reachable if its list item points at it, so this pairs pointers and
# notes in both directions rather than pinning either one's wording. gumroad-private#1713.
describe "app/views/home/prohibited.html.erb clarifying notes" do
  let(:source) { Rails.root.join("app/views/home/prohibited.html.erb").read }

  # "<li>gambling (...). See the note on gambling below.</li>" => "gambling"
  let(:pointers) { source.scan(/See\s+the\s+note\s+on\s+([^<.]+?)\s+below\./).flatten.map(&:strip) }

  # "<p><strong>A note on gambling.</strong>" => "gambling"
  let(:notes) { source.scan(/<strong>\s*A\s+note\s+on\s+([^<.]+?)\.\s*<\/strong>/).flatten.map(&:strip) }

  it "pairs every pointer with a note and every note with a pointer" do
    expect(pointers).to match_array(notes)
  end

  # Without this, both scans returning [] makes the pairing assertion [] == [] on a page with no
  # notes at all.
  it "finds both maintained notes" do
    expect(notes).to match_array(["fortune tellers", "gambling"])
  end

  describe "the fortune teller note" do
    let(:note) do
      source[/<strong>\s*A\s+note\s+on\s+fortune\s+tellers\.\s*<\/strong>.*?(?=<p>\s*<strong>|<\/div>)/m]
    end

    # Otherwise the include examples below fail on nil rather than on their subject.
    it "slices a note out of the page" do
      expect(note).to_not be_nil
    end

    it "is reachable from its list entry" do
      expect(source).to include("<li>fortune tellers. See the note on fortune tellers below.</li>")
    end

    # "tarot" alone would also be satisfied by the Discover URL inside the slice, so this asserts
    # prose-only words too.
    it "names the allowed traditions" do
      expect(note).to include("astrology", "tarot", "divination", "numerology", "birth-chart")
    end

    # A widened slice would swallow the next note and every include above would still pass.
    it "stops before the gambling note" do
      expect(note).to_not include("A note on gambling")
    end

    it "states what remains prohibited" do
      expect(note).to include("prediction service")
    end
  end

  # The source scans above stay green if the route helper is renamed away (page 500s) or if `<%=`
  # becomes `<%`. Only rendered output settles whether a reader can click through.
  describe "the rendered Discover link" do
    # A bare slug is NOT a Discover URL — DiscoverTaxonomyConstraint matches the full ancestry path
    # only, so gumroad.com/tarot falls through to the username route and lands on whichever creator
    # owns that handle. Reading (never creating) tarot from the seeded canonical tree means a
    # seed-only rename or reparent changes the derived path here and reddens the assertion below;
    # `sole` keeps that loud rather than picking an arbitrary row if a duplicate ever appears.
    let(:tarot_path) do
      Taxonomy.where(slug: "tarot").sole.self_and_ancestors.reverse.map(&:slug).join("/")
    end

    let(:rendered) { ApplicationController.render(template: "home/prohibited", layout: false) }

    it "points at the tarot category's canonical ancestry path" do
      expect(rendered).to include(%(href="#{UrlService.discover_domain_with_protocol}/#{tarot_path}"))
    end
  end
end
