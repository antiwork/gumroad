# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit custom permalink edit", type: :system, js: true) do
  include ManageSubscriptionHelpers
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  before :each do
    product.shipping_destinations << ShippingDestination.new(
      country_code: Product::Shipping::ELSEWHERE,
      one_item_rate_cents: 0,
      multiple_items_rate_cents: 0
    )
    product.custom_permalink = SecureRandom.alphanumeric(5)
    product.save!
  end

  def custom_permalink_input
    find_field("URL")
  end

  def custom_permalink_field
    custom_permalink_input.find(:xpath, "..")
  end

  include_context "with switching account to user as admin for seller"

  it "has the correct domain prefix" do
    visit edit_link_path(product.unique_permalink)
    expect(custom_permalink_field).to have_text("#{seller.username}.#{ROOT_DOMAIN}/l/")
  end

  it "links to the correct product page" do
    visit edit_link_path(product.unique_permalink)
    prefix_from_page = custom_permalink_field.text
    custom_permalink_from_page = custom_permalink_input.value
    custom_permalink_url = "#{PROTOCOL}://#{prefix_from_page}#{custom_permalink_from_page}"
    using_session("visit custom permalink url") do
      visit(custom_permalink_url)
      expect(page).to have_text(product.name)
      expect(page).to have_text(product.user.name)
    end
  end

  it "allows copying the url" do
    visit edit_link_path(product.unique_permalink)
    within(find("label", text: "URL").ancestor("section")) do
      expect(page).not_to have_content("Copy to Clipboard")
      copy_link = find_button("Copy URL")
      copy_link.hover
      expect(page).to have_content("Copy to Clipboard")

      copy_link.click
      expect(page).to have_content("Copied!")

      # Hover somewhere else to trigger mouseout
      find("label", text: "URL").hover
      expect(page).not_to have_content("Copy to Clipboard")
      expect(page).not_to have_content("Copied!")
    end
  end

  describe "updates all share urls on change" do
    before :each do
      product.custom_permalink = SecureRandom.alphanumeric(5)
      product.save!
      @new_custom_permalink = SecureRandom.alphanumeric(5)
    end

    def visit_product_and_update_custom_permalink(product)
      visit edit_link_path(product.unique_permalink)
      custom_permalink_input.set("").set(@new_custom_permalink)
      save_change
    end

    def get_new_custom_permalink_url(subpath: "", query_params: {})
      base_url = "#{seller.subdomain_with_protocol}/l/#{@new_custom_permalink}"
      base_url_with_subpath = subpath == "" ? base_url : "#{base_url}/#{js_style_encode_uri_component(subpath)}"

      query_params_string = URI.encode_www_form(query_params)
      full_url = query_params_string == "" ? base_url_with_subpath : "#{base_url_with_subpath}?#{query_params_string}"
      full_url
    end

    it "changes membership tier share url" do
      @membership_product = create(:membership_product, user: seller)
      first_tier = @membership_product.tier_category.variants.first
      first_tier.name = "First Tier"
      first_tier.save!

      visit_product_and_update_custom_permalink(@membership_product)

      within tier_rows[0] do
        expect(page).to have_link("Share", href: get_new_custom_permalink_url(query_params: { option: first_tier.external_id }))
      end
    end

    it "changes digital version share url" do
      @variant_category = product.variant_categories.new
      @variant_category.title = "Version Group 1"
      @variant_option = @variant_category.variants.new
      @variant_option.product_files << product.product_files.alive.first
      @variant_option.name = "Group 1 Version 1"
      @variant_option.save

      visit_product_and_update_custom_permalink(product)

      within version_rows[0] do
        within version_option_rows[0] do
          expect(page).to have_link("Share", href: get_new_custom_permalink_url(query_params: { option: @variant_option.external_id }))
        end
      end
    end
  end
end
