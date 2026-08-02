# frozen_string_literal: true

require "spec_helper"

# The prohibited list carries bare category names, so a category we actually operate a Discover
# section for (tarot/astrology under item 28) reads as a flat ban. The fix is a clarifying note, and
# a note is only reachable if the list item points at it — so this asserts the pointer and the note
# stay paired in both directions rather than pinning either one's wording. gumroad-private#1713.
#
# Ruby's \s does not match U+00A0 and this file's hand-maintained markup mixes both, so a \s gap
# silently skips nbsp-gapped rows. POSIX [[:space:]] matches both.
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
      source[/<strong>#{sp}*A#{sp}+note#{sp}+on#{sp}+fortune#{sp}+tellers\.#{sp}*<\/strong>.*?(?=<p><strong>)/om]
    end

    it "is reachable from item 28" do
      expect(source).to include("<li>fortune tellers. See the note on fortune tellers below.</li>")
    end

    # The seller-visible point of the note: the categories we ship in Discover are named as allowed.
    it "names the allowed traditions and links the Discover category" do
      expect(note).to include("astrology", "tarot", "divination")
      expect(note).to include("https://discover.gumroad.com/tarot")
    end

    it "states what remains prohibited" do
      expect(note).to include("prediction service")
    end
  end
end
