# frozen_string_literal: true

require "spec_helper"

describe Page do
  let(:product) { create(:product) }
  let(:user) { create(:user) }

  describe "root pages (custom HTML takeovers)" do
    it "normalizes blank custom_html to nil" do
      page = described_class.create!(pageable: product, custom_html: "")

      expect(page.reload.custom_html).to be_nil
    end

    it "normalizes custom_html to nil when sanitization removes all content" do
      page = described_class.create!(pageable: product, custom_html: %(<script src="https://evil.com/x.js"></script>))

      expect(page.reload.custom_html).to be_nil
    end

    it "allows only one root page per owner" do
      described_class.create!(pageable: user, custom_html: "<h1>Root</h1>")
      duplicate = described_class.new(pageable: user, custom_html: "<h1>Another root</h1>")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end

    it "allows a root page alongside slugged pages" do
      described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")
      root = described_class.new(pageable: user, custom_html: "<h1>Root</h1>")

      expect(root).to be_valid
    end
  end

  describe "slugged pages (first-class Pages)" do
    it "requires a title" do
      page = described_class.new(pageable: user, slug: "about", content: "<p>Hi</p>")

      expect(page).not_to be_valid
      expect(page.errors[:title]).to be_present
    end

    it "rejects slugs with invalid characters" do
      %w[About about_me -about about- a--b].each do |slug|
        page = described_class.new(pageable: user, slug:, title: "About", content: "<p>Hi</p>")
        expect(page).not_to be_valid, "expected #{slug.inspect} to be invalid"
      end
    end

    it "accepts well-formed slugs" do
      %w[about about-me faq2 a-b-c].each do |slug|
        page = described_class.new(pageable: user, slug:, title: "About", content: "<p>Hi</p>")
        expect(page).to be_valid, "expected #{slug.inspect} to be valid: #{page.errors.full_messages}"
      end
    end

    it "rejects reserved slugs that would shadow storefront routes" do
      %w[l d p posts library follow subscribe pages].each do |slug|
        page = described_class.new(pageable: user, slug:, title: "About", content: "<p>Hi</p>")
        expect(page).not_to be_valid, "expected #{slug.inspect} to be reserved"
        expect(page.errors[:slug]).to include("is reserved")
      end
    end

    it "enforces slug uniqueness per owner but not across owners" do
      described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")

      duplicate = described_class.new(pageable: user, slug: "about", title: "About again", content: "<p>Hi</p>")
      expect(duplicate).not_to be_valid

      other_owner = described_class.new(pageable: create(:user), slug: "about", title: "About", content: "<p>Hi</p>")
      expect(other_owner).to be_valid
    end

    it "only allows users to have slugged pages" do
      page = described_class.new(pageable: product, slug: "about", title: "About", content: "<p>Hi</p>")

      expect(page).not_to be_valid
      expect(page.errors[:pageable_type]).to be_present
    end

    it "sanitizes rich text content down to editor-supported markup" do
      page = described_class.create!(
        pageable: user, slug: "about", title: "About",
        content: %(<p>Hello</p><script>alert(1)</script><p onclick="alert(2)">World</p>)
      )

      expect(page.reload.content).to include("<p>Hello</p>")
      expect(page.content).not_to include("<script>")
      expect(page.content).not_to include("onclick")
    end

    it "keeps custom_html and content independent so an agent takeover wins over rich text" do
      page = described_class.create!(pageable: user, slug: "studio", title: "Studio", content: "<p>Rich text</p>")
      page.update!(custom_html: "<h1>Custom</h1>")

      expect(page.reload.custom_html).to include("Custom")
      expect(page.content).to include("Rich text")
    end
  end

  describe "associations" do
    it "scopes User#page to the root page and User#pages to slugged pages" do
      root = described_class.create!(pageable: user, custom_html: "<h1>Root</h1>")
      slugged = described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")

      expect(user.reload.page).to eq(root)
      expect(user.pages).to eq([slugged])
    end
  end
end
