# frozen_string_literal: true

require "spec_helper"

describe("Discover - Nav - Mobile", :js, :mobile_view, type: :system) do
  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    software_taxonomy = Taxonomy.find_by(slug: "software-development")
    @software_product = create(:product, user: create(:compliant_user), name: "Software Product", price_cents: 100, taxonomy: software_taxonomy)
    create(:product_review, purchase: create(:purchase, link: @software_product), rating: 1)

    programming_taxonomy = Taxonomy.find_by(slug: "programming", parent: software_taxonomy)
    @programming_product = create(:product, user: create(:compliant_user), name: "Programming Product", price_cents: 200, taxonomy: programming_taxonomy)
    create(:product_review, purchase: create(:purchase, link: @programming_product), rating: 2)

    index_model_records(Purchase)
    index_model_records(Link)
  end

  it "allows navigation to top-level and nested categories" do
    visit discover_url(host: discover_host)

    click_on "Categories"
    within "[role=menu]" do
      click_on "Software Development"
      click_on "All Software Development"
    end

    within_section "Featured products", section_element: :section do
      expect_product_cards_in_order([@programming_product, @software_product])
    end

    click_on "Categories"
    within "[role=menu]" do
      click_on "Software Development"
      click_on "Programming"
      click_on "All Programming"
    end

    within_section "Featured products", section_element: :section do
      expect_product_cards_in_order([@programming_product])
    end
  end

  it "dismisses the menu via the close menu button" do
    visit discover_url(host: discover_host)

    # 'All' is the first option of the nav
    expect(page).not_to have_selector("[role=menuitem]", text: "All")

    click_on "Categories"
    expect(page).to have_text("All")

    click_on "Close Menu"
    expect(page).not_to have_text("All")
  end
end
