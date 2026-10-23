# frozen_string_literal: true

require "spec_helper"

describe Pages::RichTextDocument do
  describe ".render" do
    let(:page) { build(:user_page, title: "About", content: "<p>Hello</p>") }

    it "styles TipTap insert-button links so they publish as buttons, not plain text" do
      html = described_class.render(page:, seller_name: "Jane")

      expect(html).to include("article a.tiptap__button")
      expect(html).to match(/a\.tiptap__button[^}]*background:\s*#ff90e8/)
      expect(html).to match(/a\.tiptap__button[^}]*color:\s*#000/)
      expect(html).to match(/a\.tiptap__button[^}]*box-shadow:\s*0\.25rem 0\.25rem 0 #000/)
    end

    it "still renders the page title, byline, and content" do
      html = described_class.render(page:, seller_name: "Jane", profile_href: "/jane")

      expect(html).to include("About — Jane")
      expect(html).to include(%(href="/jane"))
      expect(html).to include("<p>Hello</p>")
    end

    it "does not append the seller name when the page title already ends with it" do
      titled_page = build(:user_page, title: "About | Jane", content: "<p>Hello</p>")

      html = described_class.render(page: titled_page, seller_name: "Jane")

      expect(html).to include("<title>About | Jane</title>")
    end

    it "uses the seller's SEO title as written" do
      page.seo_title = "Hand-lettered posters"

      html = described_class.render(page:, seller_name: "Jane")

      expect(html).to include("<title>Hand-lettered posters</title>")
      expect(html).to include(%(<h1 class="page-title">About</h1>))
    end
  end
end
