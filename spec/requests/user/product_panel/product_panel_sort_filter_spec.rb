# frozen_string_literal: true

require("spec_helper")

describe("Product panel on creator profile - Sort/Filter", type: :system, js: true) do
  before do
    @creator = create(:named_user)
    purchaser_email = "one@gr.test"
    @preview_image_url = "https://s3.amazonaws.com/gumroad-specs/specs/kFDzu.png"
    @a = create(:product_with_files, user: @creator, name: "Digital Product A", price_cents: 300, created_at: 20.minutes.ago, preview_url: @preview_image_url)
    @a.tag!("Audio")
    @b = create(:product, user: @creator, name: "Physical Product B", price_cents: 200, created_at: 19.minutes.ago)
    @b.tag!("Video")
    @b.tag!("Book")
    purchase_b1 = create(:purchase, link: @b, email: purchaser_email)
    create(:product_review, purchase: purchase_b1, rating: 4)
    purchase_b2 = create(:purchase, link: @b, email: purchaser_email)
    create(:product_review, purchase: purchase_b2, rating: 1)
    @c = create(:product, user: @creator, name: "Digital Subscription C", price_cents: 400, created_at: 18.minutes.ago)
    @c.tag!("Book")
    purchase_c1 = create(:purchase, link: @c, email: purchaser_email)
    create(:product_review, purchase: purchase_c1, rating: 3)
    purchase_c2 = create(:purchase, link: @c, email: purchaser_email)
    create(:product_review, purchase: purchase_c2, rating: 3)

    recurrence_price_values_d = [
      { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 1 } },
      { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 1.5 } }
    ]
    @d = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values: recurrence_price_values_d, name: "Physical Subscription D", user: @creator, created_at: 17.minutes.ago)
    @d.tag!("Audio")

    @e = create(:product, price_cents: 400, name: "Digital Preorder E", user: @creator, created_at: 16.minutes.ago)
    create(:variant, variant_category: create(:variant_category, link: @e), price_difference_cents: 100)
    @e.tag!("Audio")
    @hideme = create(:product_with_files, user: @creator, name: "Hidden")
    @f = create(:product, user: @creator, name: "Digital Product F", price_cents: 110, created_at: 15.minutes.ago)
    purchase_f = create(:purchase, link: @f, email: purchaser_email)
    create(:product_review, purchase: purchase_f, rating: 2)
    @g = create(:product, user: @creator, name: "Digital Product G", price_cents: 120, created_at: 14.minutes.ago, display_product_reviews: false)
    purchase_g = create(:purchase, link: @g, email: purchaser_email)
    create(:product_review, purchase: purchase_g, rating: 2)
    @h = create(:product, user: @creator, name: "Digital Product H", price_cents: 130, created_at: 13.minutes.ago)
    purchase_h = create(:purchase, link: @h, email: purchaser_email)
    create(:product_review, purchase: purchase_h, rating: 1)
    @i = create(:product, user: @creator, name: "Digital Product I", price_cents: 140, created_at: 12.minutes.ago)
    @j = create(:product, user: @creator, name: "Digital Product J", price_cents: 150, created_at: 11.minutes.ago)
    @section = create(:seller_profile_products_section, seller: @creator, shown_products: [@a, @b, @c, @d, @e, @f, @g, @h, @i, @j].map { _1.id }, show_filters: true)
    create(:seller_profile, seller: @creator, json_data: { tabs: [{ name: "Products", sections: [@section.id] }] })
    Link.import(refresh: true, force: true)
  end

  it("allows other users to sort the products") do
    login_as(create(:user))
    visit("/#{@creator.username}")
    expect_product_cards_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i])

    toggle_disclosure "Sort by"
    choose "Price (Low to High)"
    wait_for_ajax
    expect_product_cards_in_order([@d, @f, @g, @h, @i, @j, @b, @a, @c])

    choose "Highest rated"
    wait_for_ajax
    expect_product_cards_in_order([@c, @b, @g, @f, @h, @j, @i, @e, @d])

    choose "Most reviewed"
    wait_for_ajax
    expect_product_cards_in_order([@c, @b, @h, @g, @f, @j, @i, @e, @d])
  end

  it("allows other users to search for products") do
    login_as(create(:user))
    visit("/#{@creator.username}")
    expect_product_cards_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i])
    fill_in "Search products", with: "Physical\n"
    sleep 2 # because there's an explicit delay in the javascript handler
    wait_for_ajax
    expect_product_cards_in_order([@b, @d])
  end


  describe "Filetype filter" do
    before do
      # seed PDF
      create(:product_file, link: @a)

      # seed ZIP
      create(:product_file, link: @b, url: "https://s3.amazonaws.com/gumroad-specs/specs/preorder.zip")
      @c.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/specs/preorder.zip")

      # seed MP3
      @c.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3")
      @c.save!

      Link.import(refresh: true, force: true)
    end

    it "handles filetype filters properly" do
      visit("/#{@creator.username}")
      toggle_disclosure "Contains"
      check "pdf (1)"
      wait_for_ajax
      expect(page).to have_product_card(count: 1)
      expect(page).to have_product_card(text: "Digital Product A")

      check "zip (2)"
      wait_for_ajax
      # filetype filters are additive, e.g. if both PDF + ZIP are selected we should be
      # seeing A (PDF) and B, C (ZIP)
      expect_product_cards_in_order([@a, @b, @c])

      uncheck "zip (2)"
      wait_for_ajax
      uncheck "pdf (1)"
      wait_for_ajax

      check "mp3 (1)"
      wait_for_ajax
      expect(page).to have_product_card(count: 1)
      expect(page).to have_product_card(text: "Digital Subscription C")

      uncheck "mp3 (1)"
      wait_for_ajax
      expect_product_cards_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i])
    end
  end

  it "allows other users to filter by price" do
    login_as(create(:user))
    visit("/#{@creator.username}")

    toggle_disclosure "Price"

    fill_in "Minimum price", with: "2"
    wait_for_ajax
    expect_product_cards_in_order([@a, @b, @c, @e])

    fill_in "Maximum price", with: "4"
    wait_for_ajax
    expect_product_cards_in_order([@a, @b, @c])

    fill_in "Minimum price", with: ""
    fill_in "Maximum price", with: ""
    wait_for_ajax
    expect_product_cards_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i])
  end

  it("displays products sorted by default_product_sort") do
    @section.update!(default_product_sort: ProductSortKey::PRICE_ASCENDING)

    visit("/#{@creator.username}")
    toggle_disclosure "Sort by"
    expect(page).to have_checked_field("Price (Low to High)")
    expect_product_cards_in_order([@d, @f, @g, @h, @i, @j, @b, @a, @c])
  end

  it("allows users to search for products with selected tags and sort them") do
    login_as(create(:user))
    visit("/#{@creator.username}")
    expect_product_cards_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i])
    toggle_disclosure "Tags"
    check "audio (3)"
    wait_for_ajax
    expect_product_cards_in_order([@a, @d, @e])
    fill_in "Search products", with: "digital\n"
    sleep 2 # because there's an explicit delay in the javascript handler
    wait_for_ajax
    expect_product_cards_in_order([@a, @e])
    toggle_disclosure "Sort by"
    choose "Price (High to Low)"
    wait_for_ajax
    expect_product_cards_in_order([@e, @a])
    uncheck "audio (2)"
    expect_product_cards_in_order([@e, @c, @a, @j, @i, @h, @g, @f])
    fill_in("Search products", with: "")
    find_field("Search products").native.send_keys(:return)
    sleep 2 # because there's an explicit delay in the javascript handler
    wait_for_ajax
    expect_product_cards_in_order([@e, @c, @a, @b, @j, @i, @h, @g, @f])
  end

  it "allows to reset active filters" do
    @section.update!(default_product_sort: ProductSortKey::HIGHEST_RATED)

    login_as(create(:user))
    visit("/#{@creator.username}")

    expect(page).to have_text("1-9 of 10 products")
    expect(page).to_not have_button("Clear")
    toggle_disclosure "Sort by"
    expect(page).to have_checked_field("Highest rated")

    # Apply some filters
    choose "Most reviewed"
    wait_for_ajax
    toggle_disclosure "Price"
    fill_in "Maximum price", with: "2"
    wait_for_ajax

    expect(page).to have_text("1-7 of 7 products")
    expect(page).to have_button("Clear")
    expect(page).to have_checked_field("Most reviewed")

    # Reset the applied filters
    click_on("Clear")
    wait_for_ajax

    expect(page).to have_text("1-9 of 10 products")
    expect(page).to_not have_button("Clear")
    expect(page).to have_checked_field("Highest rated")
  end

  it "hides 'Show NSFW' toggle and always displays NSFW products" do
    @a.update!(is_adult: true)
    Link.import(refresh: true, force: true)

    visit("/#{@creator.username}")

    expect(page).to_not have_text("Show NSFW")
    expect(page).to have_product_card(text: "Digital Product A")
  end
end
