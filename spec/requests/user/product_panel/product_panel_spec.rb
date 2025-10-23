# frozen_string_literal: true

require("spec_helper")

describe("Product panel on creator profile", type: :system, js: true) do
  before do
    @creator = create(:named_user)
    purchaser_email = "one@gr.test"
    @preview_image_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/kFDzu.png"
    @a = create(:product_with_files, user: @creator, name: "Digital Product A", created_at: 20.minutes.ago, preview_url: @preview_image_url)
    @a.tag!("Audio")
    create(:price, link: @a, price_cents: 300)
    @b = create(:product, user: @creator, name: "Physical Product B", created_at: 19.minutes.ago)
    @b.tag!("Video")
    @b.tag!("Book")
    create(:price, link: @b, price_cents: 200)
    purchase_b1 = create(:purchase, link: @b, email: purchaser_email)
    create(:product_review, purchase: purchase_b1, rating: 4)
    purchase_b2 = create(:purchase, link: @b, email: purchaser_email)
    create(:product_review, purchase: purchase_b2, rating: 1)
    @c = create(:product, user: @creator, name: "Digital Subscription C", created_at: 18.minutes.ago)
    @c.tag!("Book")
    create(:price, link: @c, price_cents: 400)
    purchase_c1 = create(:purchase, link: @c, email: purchaser_email)
    create(:product_review, purchase: purchase_c1, rating: 3)
    purchase_c2 = create(:purchase, link: @c, email: purchaser_email)
    create(:product_review, purchase: purchase_c2, rating: 3)
    @d = create(:product, user: @creator, name: "Physical Subscription D", created_at: 17.minutes.ago)
    @d.tag!("Audio")
    create(:price, link: @d, price_cents: 100)
    @e = create(:product, user: @creator, name: "Digital Preorder E", created_at: 16.minutes.ago)
    @e.tag!("Audio")
    create(:price, link: @e, price_cents: 500)
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
    section = create(:seller_profile_products_section, seller: @creator, shown_products: [@a, @b, @c, @d, @e, @f, @g, @h, @i, @j].map { _1.id }, show_filters: true)
    create(:seller_profile, seller: @creator, json_data: { tabs: [{ name: "Products", sections: [section.id] }] })
    Link.import(refresh: true, force: true)
  end

  it "shows a product's asset preview if set" do
    login_as(@creator)
    visit("/#{@creator.username}")
    expect(page.first("article figure img")[:src]).to match(PUBLIC_STORAGE_S3_BUCKET)

    login_as(create(:user))
    visit("/#{@creator.username}")
    expect(page.first("article figure img")[:src]).to match(PUBLIC_STORAGE_S3_BUCKET)
  end

  it "only shows products that have been selected to be shown" do
    login_as(create(:user))
    visit("/#{@creator.username}")
    expect_product_cards_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i])
    expect(page).to_not have_product_card(@hideme)
  end

  it "shows sold out banner on product card when max_purchase_count has been reached" do
    @a.max_purchase_count = 3
    @a.save!
    3.times { create(:purchase, link: @a) }
    login_as(create(:user))
    visit("/#{@creator.username}")
    expect(find_product_card(@a)).to have_text("0 left")
  end
end
