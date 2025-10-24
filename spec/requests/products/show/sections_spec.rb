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
    expect(page).to have_selector("section:nth-child(2) h2", text: "Section 1")
    within_section "Section 1", section_element: :section do
      expect_product_cards_in_order(products)
    end

    expect(page).to have_selector("section:nth-child(3) h2", text: "Section 2")
    within_section "Section 2", section_element: :section do
      expect(page).to have_link(count: 2)
      posts.each { expect(page).to have_link(_1.name, href: "/p/#{_1.slug}") }
    end

    expect(page).to have_selector("section:nth-child(4) article", text: product.name)

    expect(page).to have_selector("section:nth-child(5) h2", text: "Section 3")
    within_section "Section 3", section_element: :section do
      expect(page).to have_selector("h2", text: "Heading")
      expect(page).to have_text("Some more text")
    end

    expect(page).to have_selector("section:nth-child(6) h2", text: "Section 5")
    within_section "Section 4", section_element: :section do
      expect(page).to have_field "Your email address"
      expect(page).to have_button "Subscribe"
    end

    expect(page).to have_selector("section:nth-child(7) h2", text: "Section 4")
    within_section "Section 5", section_element: :section do
      expect(page).to have_section("Featured product", section_element: :article)
    end
  end

  it "allows editing sections when the user is logged in", :elasticsearch_wait_for_refresh do
    login_as seller
    product2 = create(:product, user: seller, name: "Product 2")
    visit short_link_path(product)

    select_disclosure "Add section", match: :first do
      click_on "Products"
    end
    select_disclosure "Edit section" do
      click_on "Products"
      check product2.name
    end
    toggle_disclosure "Edit section"
    click_on "Move section down"

    select_disclosure "Add section", match: :first do
      click_on "Featured Product"
    end
    sleep 1
    select_disclosure "Edit section", match: :first do
      click_on "Featured Product"
      select_combo_box_option search: product2.name, from: "Featured Product"
    end

    all(:disclosure, "Add section").last.select_disclosure do
      click_on "Posts"
    end
    sleep 1
    all(:disclosure, "Edit section").last.select_disclosure do
      click_on "Name"
      fill_in "Name", with: "Posts!"
    end

    all(:disclosure, "Add section").last.select_disclosure do
      click_on "Subscribe"
    end
    sleep 1

    all(:disclosure, "Add section")[2].select_disclosure do
      click_on "Rich text"
    end
    sleep 1
    edit_rich_text_disclosure = all(:disclosure, "Edit section")[1]
    edit_rich_text_disclosure.select_disclosure do
      click_on "Name"
      fill_in "Name", with: "Rich text!"
    end
    edit_rich_text_disclosure.toggle_disclosure

    # all these sleeps can hopefully be cleaned up when flashMessage is in react and less buggy
    sleep 1
    wait_for_ajax
    expect(page).to_not have_alert
    sleep 3
    rich_text_editor = find("[contenteditable=true]")
    rich_text_editor.send_keys "Text!\t"
    sleep 1
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")
    rich_text_editor.click
    attach_file(file_fixture("test.jpg")) do
      click_on "Insert image"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    expect(page).to_not have_alert
    sleep 3
    all(:button, "Move section up").last.click
    sleep 1
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    products_section = seller.seller_profile_products_sections.reload.sole
    expect(products_section).to have_attributes(shown_products: [product2.id], product:)

    posts_section = seller.seller_profile_posts_sections.sole
    expect(posts_section).to have_attributes(header: "Posts!", product:)

    featured_product_section = seller.seller_profile_featured_product_sections.sole
    expect(featured_product_section).to have_attributes(featured_product_id: product2.id, product:)

    subscribe_section = seller.seller_profile_subscribe_sections.sole
    expect(subscribe_section).to have_attributes(header: "Subscribe to receive email updates from #{seller.name_or_username}.", product:)

    rich_text_section = seller.seller_profile_rich_text_sections.sole
    Selenium::WebDriver::Wait.new(timeout: 10).until { rich_text_section.reload.text["content"].map { _1["type"] }.include?("image") }
    image_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{ActiveStorage::Blob.last.key}"
    expected_rich_text = {
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "Text!" }] },
        { type: "image", attrs: { src: image_url, link: nil } }
      ]
    }.as_json
    expect(rich_text_section).to have_attributes(header: "Rich text!", text: expected_rich_text, product:)

    expect(product.reload).to have_attributes(sections: [featured_product_section, rich_text_section, products_section, subscribe_section, posts_section].map(&:id), main_section_index: 1)

    refresh
    within_section "Rich text!" do
      expect(page).to have_text("Text!")
      expect(page).to have_image(src: image_url)
    end
  end
end
