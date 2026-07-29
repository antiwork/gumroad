# frozen_string_literal: true

require "spec_helper"

RSpec.describe InvisibleCharacters do
  # Every character here renders as nothing (or as an ordinary space), so the literal escapes are
  # spelled out rather than pasted — a test file containing a real U+200F would be unreadable and
  # unmaintainable for exactly the reason this module exists.
  describe ".present_in?" do
    it "finds the bidirectional marks that arrive with a copy/paste out of a right-to-left document" do
      expect(described_class.present_in?("\u200Fbuyer@example.com")).to be true
      expect(described_class.present_in?("buyer\u200E@example.com")).to be true
    end

    it "finds the other zero-width characters that survive String#strip" do
      expect(described_class.present_in?("buyer\u200Bx@example.com")).to be true # zero-width space
      expect(described_class.present_in?("buyer\u2060x@example.com")).to be true # word joiner
      expect(described_class.present_in?("\uFEFFbuyer@example.com")).to be true  # byte order mark
      expect(described_class.present_in?("buyer\u00ADx@example.com")).to be true # soft hyphen
    end

    it "finds the Unicode spaces that String#strip leaves behind" do
      expect(described_class.present_in?("buyer\u00A0@example.com")).to be true  # no-break space
      expect(described_class.present_in?("buyer\u202F@example.com")).to be true  # narrow no-break space
      expect(described_class.present_in?("buyer\u3000@example.com")).to be true  # ideographic space
    end

    it "is false for an ordinary value" do
      expect(described_class.present_in?("buyer@example.com")).to be false
      expect(described_class.present_in?("Ada Lovelace")).to be false
      expect(described_class.present_in?(nil)).to be false
      expect(described_class.present_in?("")).to be false
    end

    # These two are the reason the set is a hand-picked list rather than the U+200B-U+200F range.
    # If someone later widens it, these fail and explain why they should not.
    it "treats the zero-width non-joiner as content, because it carries meaning in Persian and Indic scripts" do
      expect(described_class.present_in?("mi\u200Cravam")).to be false
    end

    it "treats the zero-width joiner as content, because it is the glue inside multi-codepoint emoji" do
      expect(described_class.present_in?("family \u{1F468}\u200D\u{1F469}\u200D\u{1F467}")).to be false
    end
  end

  describe ".remove" do
    it "deletes the format characters" do
      expect(described_class.remove("\u200Fbuyer@example.com")).to eq "buyer@example.com"
      expect(described_class.remove("buy\u200Ber@example.com")).to eq "buyer@example.com"
    end

    it "folds a Unicode space to a plain space so the word boundary survives" do
      expect(described_class.remove("Ada\u00A0Lovelace")).to eq "Ada Lovelace"
      expect(described_class.remove("Ada\u3000Lovelace")).to eq "Ada Lovelace"
    end

    it "leaves the characters that carry meaning alone" do
      expect(described_class.remove("mi\u200Cravam")).to eq "mi\u200Cravam"
      expect(described_class.remove("\u{1F468}\u200D\u{1F469}")).to eq "\u{1F468}\u200D\u{1F469}"
    end

    it "handles nil and non-string values" do
      expect(described_class.remove(nil)).to eq ""
      expect(described_class.remove(42)).to eq "42"
    end
  end

  describe ".normalize_email" do
    it "removes the invisible characters" do
      expect(described_class.normalize_email("\u200Fbuyer@example.com")).to eq "buyer@example.com"
      expect(described_class.normalize_email("buyer\u00ADx@example.com")).to eq "buyerx@example.com"
    end

    # Unlike a name, an address never legitimately contains a space, so a folded Unicode space
    # must be deleted rather than preserved as a word boundary.
    it "deletes rather than preserves a space, because an address has no word boundaries" do
      expect(described_class.normalize_email("buyer\u00A0@example.com")).to eq "buyer@example.com"
      expect(described_class.normalize_email("bu\u3000yer@example.com")).to eq "buyer@example.com"
      expect(described_class.normalize_email(" buyer@example.com ")).to eq "buyer@example.com"
    end

    it "leaves an ordinary address untouched" do
      expect(described_class.normalize_email("buyer@example.com")).to eq "buyer@example.com"
    end

    it "passes nil through so callers can tell an absent address from an empty one" do
      expect(described_class.normalize_email(nil)).to be_nil
    end
  end
end
