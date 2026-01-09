# frozen_string_literal: true

require "spec_helper"

shared_examples_for "discover navigation when layout is discover" do |selected_taxonomy: nil|
  it "shows the discover layout when the param is passed" do
    visit discover_url

    expect(page).to have_link("Log in")
    expect(page).to have_link("Start selling")
    expect(page).to have_field("Search products")
    expect(find("[role=menubar]")).to have_text("All 3D Audio Business & Money Comics & Graphic Novels Design Drawing & Painting Education Fiction Books Films", normalize_ws: true)
    expect(page).to have_selector("[aria-current=true]", text: selected_taxonomy) if selected_taxonomy

    visit non_discover_url
    expect(page).not_to have_link("Login")
    expect(page).not_to have_selector("[role=menubar]")
  end

  it "sorts discover categories using recommended products" do
    buyer = create(:buyer_user)
    purchase = create(:purchase, purchaser: buyer, email: buyer.email)
    SalesRelatedProductsInfo.find_or_create_info(
      purchase.link.id,
      create(:product, taxonomy: Taxonomy.find_by(slug: "design")).id
    ).update!(sales_count: 20)
    rebuild_srpis_cache

    login_as buyer
    visit discover_url
    expect(find("[role=menubar]")).to have_text("All Design 3D Audio Business & Money Comics & Graphic Novels More", normalize_ws: true)
  end

  it "navigates to a taxonomy page when clicking a menu item" do
    visit discover_url

    within "[role=menubar]" do
      click_on "Design"
    end

    expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Design")
    within "[role=menubar]" do
      expect(page).to have_selector("[aria-current=true]", text: "Design")
    end
  end
end
