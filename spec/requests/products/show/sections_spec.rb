# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Profile settings on product pages", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  it "renders sections correctly when the user is logged out" do
    products = create_list(:product, 3, user: seller)
    Link.import(refresh: true, force: true)

    create(:seller_profile_products_section, seller:)
    section1 = create(:seller_profile_products_section, seller:, product:, header: "Section 1", shown_products: products.map(&:id))

    create(:published_installment, seller:, shown_on_profile: true)
    posts = create_list(:audience_installment, 2, published_at: Date.yesterday, seller:, shown_on_profile: true)
    section2 = create(:seller_profile_posts_section, seller:, product:, header: "Section 2", shown_posts: posts.pluck(:id))

    section3 = create(:seller_profile_rich_text_section, seller:, product:, header: "Section 3", text: { type: "doc", content: [{ type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "Heading" }] }, { type: "paragraph", content: [{ type: "text", text: "Some more text" }] }] })
    section4 = create(:seller_profile_subscribe_section, seller:, product:, header: "Section 4")
    section5 = create(:seller_profile_featured_product_section, seller:, product:, header: "Section 5", featured_product_id: create(:product, user: seller, name: "Featured product").id)

    product.update!(sections: [section1, section2, section3, section5, section4].map(&:id), main_section_index: 2)

    visit short_link_path(product)
    expect(page).to have_selector("section:nth-child(3) h2", text: "Section 1")
    within_section "Section 1", section_element: :section do
      expect_product_cards_in_order(products)
    end

    expect(page).to have_selector("section:nth-child(4) h2", text: "Section 2")
    within_section "Section 2", section_element: :section do
      expect(page).to have_link(count: 2)
      posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
    end

    expect(page).to have_selector("section:nth-child(5) article", text: product.name)

    expect(page).to have_selector("section:nth-child(6) h2", text: "Section 3")
    within_section "Section 3", section_element: :section do
      expect(page).to have_selector("h2", text: "Heading")
      expect(page).to have_text("Some more text")
    end

    expect(page).to have_selector("section:nth-child(7) h2", text: "Section 5")
    within_section "Section 4", section_element: :section do
      expect(page).to have_field "Your email address"
      expect(page).to have_button "Subscribe"
    end

    expect(page).to have_selector("section:nth-child(8) h2", text: "Section 4")
    within_section "Section 5", section_element: :section do
      expect(page).to have_section("Featured product", section_element: :article)
    end
  end

  it "renders existing sections without inline section controls when the user is logged in", :elasticsearch_wait_for_refresh do
    login_as seller
    product2 = create(:product, user: seller, name: "Product 2")
    products_section = create(:seller_profile_products_section, seller:, product:, header: "More from this seller", shown_products: [product2.id])
    product.update!(sections: [products_section.id], main_section_index: 1)
    Link.import(refresh: true, force: true)

    visit short_link_path(product)
    expect(page).to have_link("Edit product")
    expect(page).not_to have_disclosure_button("Add section")
    expect(page).not_to have_disclosure_button("Edit section")

    within_section "More from this seller", section_element: :section do
      expect_product_cards_in_order([product2])
    end
  end

  it "paginates product sections with more than 9 products", :elasticsearch_wait_for_refresh do
    products = 12.times.map { |i| create(:product, user: seller, name: "Product #{i + 1}") }
    Link.import(refresh: true, force: true)

    section = create(
      :seller_profile_products_section,
      seller: seller,
      product: product,
      header: "More Products",
      shown_products: products.map(&:id)
    )

    product.update!(sections: [section.id], main_section_index: 0)

    visit short_link_path(product)

    within_section "More Products", section_element: :section do
      expect(page).to have_product_card(count: 9)
      expect(page).to have_product_card(products[0])
      expect(page).to_not have_product_card(products[9])
    end

    page.scroll_to :bottom
    wait_for_ajax

    within_section "More Products", section_element: :section do
      expect(page).to have_product_card(products[9])
      expect(page).to have_product_card(count: 12)
    end
  end
end
