# frozen_string_literal: true

require "spec_helper"

describe HelpCenter::ArticleText do
  let(:article) { HelpCenter::Article.find_by!(slug: "124-your-gumroad-profile-page") }

  describe ".for" do
    it "returns the article's prose with the HTML markup stripped" do
      text = described_class.for(article)

      expect(text).to include("Your profile allows you to have your own website on Gumroad")
      expect(text).not_to include("<p>")
      expect(text).not_to include("</div>")
    end

    it "puts block elements on their own lines so lists don't read as one run-on sentence" do
      text = described_class.for(article)

      expect(text).to include("Set up your profile\n")
    end

    # Several articles embed screenshots, a few of them as base64 data URLs hundreds of kilobytes
    # long. Passing those through would be useless to a reader and would blow up the response size.
    it "drops images and other non-prose elements" do
      text = described_class.for(HelpCenter::Article.find_by!(slug: "101-designing-your-product-page"))

      expect(text).not_to include("cloudfront.net")
      expect(text).not_to include("base64")
    end

    it "caps the length and points at the live article when it truncates" do
      stub_const("#{described_class}::MAX_LENGTH", 200)
      # Cache key is per-slug, so clear it or the uncapped text from an earlier example is returned.
      Rails.cache.clear

      text = described_class.for(article)

      expect(text.length).to be <= 200
      expect(text).to include("/help/article/124-your-gumroad-profile-page")
    end

    it "reads every article without raising" do
      expect { HelpCenter::Article.all.each { |a| described_class.for(a) } }.not_to raise_error
    end
  end

  describe ".index" do
    it "summarizes every article with the slug needed to read it" do
      index = described_class.index

      expect(index.length).to eq(HelpCenter::Article.count)
      entry = index.find { |a| a[:slug] == "124-your-gumroad-profile-page" }
      expect(entry[:title]).to eq(article.title)
      expect(entry[:url]).to end_with("/help/article/124-your-gumroad-profile-page")
      expect(entry[:category]).to be_present
      # The bodies are deliberately excluded: the whole help center is far too large for one response.
      expect(entry.keys).not_to include(:content)
    end
  end

  describe ".search" do
    it "requires every term to match, so more words narrow the result" do
      broad = described_class.search("profile")
      narrow = described_class.search("profile page")

      expect(broad.length).to be >= narrow.length
      expect(narrow.map { |a| a[:slug] }).to include("124-your-gumroad-profile-page")
    end

    it "matches case-insensitively" do
      expect(described_class.search("PROFILE").map { |a| a[:slug] }).to include("124-your-gumroad-profile-page")
    end

    it "returns the full index for a blank query" do
      expect(described_class.search("  ").length).to eq(HelpCenter::Article.count)
    end

    it "returns nothing for a query that matches no article" do
      expect(described_class.search("zzzzz-not-a-real-topic")).to eq([])
    end
  end
end
