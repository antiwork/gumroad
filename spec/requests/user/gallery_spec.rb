# frozen_string_literal: true

require("spec_helper")

describe "User Gallery Page Scenario", :elasticsearch_wait_for_refresh, type: :system, js: true do
  describe "Product thumbnails", :sidekiq_inline do
    before do
      @creator = create(:user, username: "creatorgal")
      section = create(:seller_profile_products_section, seller: @creator)
      create(:seller_profile, seller: @creator, json_data: { tabs: [{ name: "", sections: [section.id] }] })
      create(:product, user: @creator)
      @product_with_previews = create(:product, user: @creator, name: "Product with previews")
      create(:asset_preview, link: @product_with_previews, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      create(:asset_preview, link: @product_with_previews)
      create(:product_review, purchase: create(:purchase, link: @product_with_previews), rating: 3)
      create(:product_review, purchase: create(:purchase, link: @product_with_previews), rating: 4)

      create(:thumbnail, product: @product_with_previews)
      @product_with_previews.reload

      Link.import(refresh: true, force: true)
    end

    it "displays product thumbnail instead of previews" do
      visit("/creatorgal")
      within find_product_card(@product_with_previews) do
        expect(find("figure")).to have_image(src: @product_with_previews.thumbnail.url)
      end
    end
  end

  describe "Product previews", :sidekiq_inline do
    before do
      @creator = create(:user, username: "creatorgal")
      section = create(:seller_profile_products_section, seller: @creator)
      create(:seller_profile, seller: @creator, json_data: { tabs: [{ name: "", sections: [section.id] }] })
      create(:product, user: @creator)
      @product_with_previews = create(:product, user: @creator, name: "Product with previews")
      create(:asset_preview, link: @product_with_previews, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", attach: false)
      create(:asset_preview, link: @product_with_previews)
      create(:product_review, purchase: create(:purchase, link: @product_with_previews), rating: 3)
      create(:product_review, purchase: create(:purchase, link: @product_with_previews), rating: 4)
      Link.import(refresh: true, force: true)
    end

    it "uses the first image cover as the preview" do
      visit("/creatorgal")
      within find_product_card(@product_with_previews) do
        expect(find("figure")).to have_image(src: @product_with_previews.asset_previews.last.url)
      end
    end

    it "displays average rating with reviews count if product reviews are enabled" do
      visit("/creatorgal")
      within find_product_card(@product_with_previews) do
        within("[aria-label=Rating]") do
          expect(page).to have_content("3.5 (2)", normalize_ws: true)
        end
      end

      @product_with_previews.display_product_reviews = false
      @product_with_previews.save!
      visit "/creatorgal"
      within find_product_card(@product_with_previews) do
        expect(page).not_to have_selector("[aria-label=Rating]")
      end
    end
  end

  describe "product share_url" do
    before do
      @user = create(:named_user)
      section = create(:seller_profile_products_section, seller: @user)
      create(:seller_profile, seller: @user, json_data: { tabs: [{ name: "", sections: [section.id] }] })
      @product = create(:product, user: @user)
    end

    it "contains link to individual product page with long_url" do
      stub_const("DOMAIN", "127.0.0.1")
      stub_const("SHORT_DOMAIN", "test.gum.co")
      visit "/#{@user.username}"

      # Custom domain pages will have share URLs with the custom domain. Since subdomain profile page works
      # the same way as custom domain, it will have share URL with subdomain of the creator.
      share_url = "#{@user.subdomain_with_protocol}/l/#{@product.unique_permalink}?layout=profile"

      expect(page).to have_link(@product.name, href: share_url)
    end
  end
end
