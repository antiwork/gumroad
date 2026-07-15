# frozen_string_literal: true

require "spec_helper"

describe Pages::DefaultProfileDocument do
  describe ".render" do
    let(:seller) { create(:user, name: "Jane Doe", bio: "Maker of things", username: "janedoe") }

    it "renders a standalone document with the creator header and bio" do
      html = described_class.render(seller)

      expect(html).to include("<!doctype html>")
      expect(html).to include("<title>Jane Doe</title>")
      expect(html).to include("<h1>Jane Doe</h1>")
      expect(html).to include(%(<p class="bio">Maker of things</p>))
    end

    it "lists the seller's live products with absolute store URLs" do
      product = create(:product, user: seller, name: "Design Course")
      draft = create(:product, user: seller, name: "Unfinished Draft", draft: true)

      html = described_class.render(seller)

      expect(html).to include("Design Course")
      expect(html).to include(product.long_url)
      expect(html).not_to include(draft.name)
    end

    it "does not link slugged pages, since the default storefront never shows those links" do
      # A pulled document must only contain what the current storefront renders:
      # a seller may rely on a slugged page being unlinked (a hidden discount
      # page, a draft shared privately), and pushing the pull back must not
      # publish navigation the storefront never had.
      create(:user_page, pageable: seller, slug: "about", title: "About me")

      html = described_class.render(seller)

      expect(html).not_to include("/about")
      expect(html).not_to include("About me")
    end

    it "uses the seller's saved profile colors" do
      seller.seller_profile.update!(background_color: "#123456", highlight_color: "#abcdef")

      html = described_class.render(seller)

      expect(html).to include("--background: #123456")
      expect(html).to include("--accent: #abcdef")
    end

    it "escapes seller-controlled text so it cannot break out of the document" do
      seller.update!(name: %(<script>alert("x")</script>))

      html = described_class.render(seller)

      expect(html).not_to include("<script>alert")
      expect(html).to include("&lt;script&gt;")
    end

    it "falls back to the default colors when a saved color is not exactly a hex color" do
      # The colors are interpolated into the <style> block, so anything that
      # isn't a plain #rrggbb value must be dropped, not escaped.
      profile = seller.seller_profile.tap(&:save!)
      profile.update_columns(background_color: "#123456; } body { display: none } /*", highlight_color: "#abcdef\n}")

      html = described_class.render(seller)

      expect(html).to include("--background: #ffffff")
      expect(html).to include("--accent: #ff90e8")
      expect(html).not_to include("display: none")
    end

    it "omits the products and posts sections when the seller has none" do
      html = described_class.render(seller)

      expect(html).not_to include("<h2>Products</h2>")
      expect(html).not_to include("<h2>Posts</h2>")
    end
  end
end
