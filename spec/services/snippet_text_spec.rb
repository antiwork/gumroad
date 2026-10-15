# frozen_string_literal: true

require "spec_helper"

describe SnippetText do
  describe ".truncate" do
    it "leaves text that already fits in a snippet untouched" do
      expect(SnippetText.truncate("A short and sweet product description.")).to eq("A short and sweet product description.")
    end

    it "caps the snippet at 160 characters" do
      snippet = SnippetText.truncate("word " * 100)

      expect(snippet.length).to be <= 160
      expect(snippet).to end_with("...")
    end

    it "cuts on a word boundary" do
      text = (1..40).map { |i| "word#{i}" }.join(" ")
      prefix = SnippetText.truncate(text).delete_suffix("...")

      expect(text).to start_with(prefix)
      expect(text[prefix.length]).to eq(" ")
    end

    context "when the cut lands on sentence punctuation" do
      let(:text) { ("a" * 153) + ". And then a lot more words to push past the cap." }

      it "replaces the punctuation with the omission instead of doubling it" do
        expect(SnippetText.truncate(text)).to eq(("a" * 153) + "...")
      end
    end

    context "when the cut lands on a comma" do
      let(:text) { ("a" * 153) + ", and then a lot more words to push past the cap." }

      it "replaces the punctuation with the omission instead of doubling it" do
        expect(SnippetText.truncate(text)).to eq(("a" * 153) + "...")
      end
    end

    context "when the cut lands on an ellipsis the seller wrote" do
      let(:text) { ("a" * 150) + "... " + ("b" * 60) }

      it "keeps one omission instead of stacking two" do
        expect(SnippetText.truncate(text)).to eq(("a" * 150) + "...")
      end
    end

    context "when the cut lands on a unicode ellipsis the seller wrote" do
      let(:text) { ("a" * 150) + "… " + ("b" * 60) }

      it "keeps one omission instead of stacking two" do
        expect(SnippetText.truncate(text)).to eq(("a" * 150) + "...")
      end
    end

    it "returns a string when there is no description" do
      expect(SnippetText.truncate(nil)).to eq("")
    end
  end
end
