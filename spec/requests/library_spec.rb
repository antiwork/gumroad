# frozen_string_literal: true

require "spec_helper"

describe("Library Scenario", type: :feature, js: true) do
  include ManageSubscriptionHelpers

  before :each do
    @user = create(:named_user)
    login_as @user
    allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
  end

  def expect_to_show_purchases_in_order(purchases)
    purchases.each_with_index do |purchase, index|
      variants = purchase.variant_attributes&.map(&:name)&.join(", ")
      expect(page).to have_selector(".product-card:nth-of-type(#{index + 1})", text: "#{purchase.link.name}#{variants.present? ? " - #{variants}" : ""}")
    end
  end

  context "membership purchases" do
    let(:product) do
      create(:membership_product, block_access_after_membership_cancellation: true,
                                  product_files: [create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png"),
                                                  create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pen.png")])
    end
    let!(:purchase1) do
      create(:membership_purchase, created_at: 1.month.ago, link: product, purchaser: @user).tap { _1.create_url_redirect! }
    end
    let!(:purchase2) do
      create(:membership_purchase, link: product, purchaser: @user).tap { _1.create_url_redirect! }
    end
    let!(:purchase3) do
      create(:membership_purchase, link: product, purchaser: @user).tap do
        _1.create_url_redirect!
        _1.subscription.update!(cancelled_at: 1.day.ago)
      end
    end

    it "shows all live subscription purchases" do
      Link.import(refresh: true, force: true)

      visit "/library"

      expect(page).to have_product_card(product, count: 2)
      expect(page).to have_link(href: purchase1.url_redirect.download_page_url)
      expect(page).to have_link(href: purchase2.url_redirect.download_page_url)
      expect(page).not_to have_link(href: purchase3.url_redirect.download_page_url)
    end
  end

  it "shows preorders purchases" do
    link = create(:product_with_video_file, price_cents: 600, is_in_preorder_state: true, name: "preorder link")
    Link.import(refresh: true, force: true)
    preorder_link = create(:preorder_link,
                           link:,
                           release_at: 2.days.from_now)
    good_card = build(:chargeable)
    preorder = create(:preorder, preorder_link_id: preorder_link.id, seller_id: link.user.id)
    create(:purchase, purchaser: @user,
                      link: preorder_link.link,
                      chargeable: good_card,
                      purchase_state: "in_progress",
                      preorder_id: preorder.id,
                      is_preorder_authorization: true)
    preorder.authorize!
    preorder.mark_authorization_successful!
    visit "/library"
    expect(page).to have_product_card(link)
  end

  describe "Product thumbnails", :sidekiq_inline do
    it "displays product thumbnail instead of previews" do
      creator = create(:user)
      product = create(:product, user: creator)
      create(:purchase, link: product, purchaser: @user)

      create(:thumbnail, product:)
      product.reload

      index_model_records(Link)

      visit "/library"

      within find_product_card(product) do
        expect(find("figure")).to have_image(src: product.thumbnail.url)
      end
    end

    context "when asset preview dimensions are nil" do
      let(:product) { create(:product) }
      let!(:asset_preview) { create(:asset_preview, link: product) }
      let!(:purchase) { create(:purchase, link: product, purchaser: @user) }

      it "displays the purchased product card" do
        allow_any_instance_of(AssetPreview).to receive(:width).and_return(nil)
        allow_any_instance_of(AssetPreview).to receive(:height).and_return(nil)

        visit "/library"

        expect(page).to have_product_card(product)
      end
    end
  end

  it "shows subscriptions where the original purchase is refunded" do
    subscription_link = create(:subscription_product, name: "some name", user: @user)
    subscription = create(:subscription, user: @user, link: subscription_link, created_at: 3.days.ago)
    purchase = create(:purchase, link: subscription_link, subscription:, is_original_subscription_purchase: true, created_at: 3.days.ago, purchaser: @user)
    create(:url_redirect, purchase:)

    non_subscription_link = create(:product, is_recurring_billing: false, user: @user)
    normal_purchase = create(:purchase, link: non_subscription_link, purchaser: @user)
    create(:url_redirect, purchase: normal_purchase)

    create(:purchase, link: subscription_link, subscription:, is_original_subscription_purchase: false, purchaser: @user)
    purchase.update_attribute(:stripe_refunded, true)
    Link.import(refresh: true, force: true)
    visit "/library"
    expect(page).to have_product_card(subscription_link)
  end

  it "shows subscriptions where the subscription plan has been upgraded" do
    setup_subscription(with_product_files: true)

    travel_to(@originally_subscribed_at + 1.month) do
      params = {
        price_id: @yearly_product_price.external_id,
        variants: [@original_tier.external_id],
        use_existing_card: true,
        perceived_price_cents: @original_tier_yearly_price.price_cents,
        perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
      }

      result =
        Subscription::UpdaterService.new(subscription: @subscription,
                                         gumroad_guid: "abc123",
                                         params:,
                                         logged_in_user: @user,
                                         remote_ip: "1.1.1.1").perform
      expect(result[:success]).to eq true

      login_as @user
      visit "/library"
      expect(page).to have_product_card(@product)
    end
  end

  it "allows archiving purchases" do
    purchase = create(:purchase, purchaser: @user)
    Link.import(refresh: true, force: true)

    # The library shows this purchase
    visit "/library"
    expect(page).to have_product_card(purchase.link)

    # Archive the purchase, which disappears from the library
    visit "/library"
    find_product_card(purchase.link).hover
    find('[aria-label="Open product action menu"]').click
    click_on "Archive"

    expect(page).to_not have_product_card(purchase.link)
  end

  it "allows unarchiving purchases" do
    purchase = create(:purchase, purchaser: @user, is_archived: true)
    Link.import(refresh: true, force: true)

    visit "/library?show_archived_only=true"
    expect(page).to have_product_card(purchase.link)

    # Unarchive the purchase, which disappears from the archives
    find_product_card(purchase.link).hover
    find('[aria-label="Open product action menu"]').click
    click_on "Unarchive"

    expect(page).to have_current_path("/library?sort=recently_updated")

    # Purchase appears again in the library
    visit "/library"
    expect(page).to have_product_card(purchase.link)
  end

  it "lists the same product several times if purchased several times" do
    products = create_list(:product, 2, name: "MyProduct")
    category = create(:variant_category, link: products[0])
    variant_1 = create(:variant, variant_category: category, name: "VariantOne")
    variant_2 = create(:variant, variant_category: category, name: "VariantTwo")
    index_model_records(Link)

    purchase_1 = create(:purchase, link: products[0], created_at: 50.minutes.ago, purchaser: @user)
    purchase_1.variant_attributes << variant_1
    purchase_2 = create(:purchase, link: products[1], created_at: 40.minutes.ago, purchaser: @user)
    purchase_3 = create(:purchase, link: products[0], created_at: 30.minutes.ago, purchaser: @user)
    purchase_3.variant_attributes << variant_2

    visit "/library"
    expect(page).to have_product_card(count: 3)
    expect_to_show_purchases_in_order([purchase_3, purchase_2, purchase_1])
  end

  describe("Search, sort and filtering") do
    before do
      @creator = create(:user, name: "A user")

      @j = create(:purchase, link: create(:product, user: @creator, name: "Product J", created_at: 50.minutes.ago, content_updated_at: 5.minutes.ago), purchaser: @user)
      @i = create(:purchase, link: create(:product, user: @creator, name: "Product I", created_at: 40.minutes.ago, content_updated_at: 6.minutes.ago), purchaser: @user)
      @h = create(:purchase, link: create(:product, user: @creator, name: "Product H", created_at: 13.minutes.ago), purchaser: @user)
      @g = create(:purchase, link: create(:product, user: @creator, name: "Product G", created_at: 14.minutes.ago), purchaser: @user)
      @f = create(:purchase, link: create(:product, user: @creator, name: "Product F", created_at: 15.minutes.ago), purchaser: @user)
      @e = create(:purchase, link: create(:product, user: @creator, name: "Product E", created_at: 16.minutes.ago), purchaser: @user)
      @d = create(:purchase, link: create(:product, user: @creator, name: "Product D", created_at: 17.minutes.ago), purchaser: @user)
      @c = create(:purchase, link: create(:product, user: @creator, name: "Product C", created_at: 18.minutes.ago), purchaser: @user)
      @b = create(:purchase, link: create(:product, user: @creator, name: "Product B", created_at: 19.minutes.ago), purchaser: @user)
      @a = create(:purchase, link: create(:product, user: @creator, name: "Product A", created_at: 20.minutes.ago), purchaser: @user)

      Link.import(refresh: true, force: true)
    end

    it("allows the purchaser to sort the library") do
      visit "/library"

      # default sorting by recently
      expect(page).to have_field("Sort by", text: "Recently Updated")
      scroll_to find_product_card(@b.link)
      expect(page).to have_product_card(count: 10)
      expect_to_show_purchases_in_order([@j, @i, @h, @g, @f, @e, @d, @c, @b, @a])
      expect(page).to have_current_path(library_path)

      # Sort by purchase date
      select "Purchase Date", from: "Sort by"
      scroll_to find_product_card(@i.link)
      expect_to_show_purchases_in_order([@a, @b, @c, @d, @e, @f, @g, @h, @i, @j])
      expect(page).to have_current_path(library_path(sort: "purchase_date"))

      # Sort by recently updated
      select "Recently Updated", from: "Sort by"
      scroll_to find_product_card(@j.link)
      scroll_to find_product_card(@b.link)
      expect_to_show_purchases_in_order([@j, @i, @h, @g, @f, @e, @d, @c, @b, @a])
      expect(page).to have_current_path(library_path(sort: "recently_updated"))
    end

    it("allows the purchaser to search the library") do
      visit("/library")
      search_field = find_field("Search products")
      search_field.fill_in with: "product B"
      search_field.native.send_keys(:enter)
      expect(page).to have_product_card(count: 1)
      expect(page).to have_product_card(@b.link)
      search_field.set("product C")
      search_field.native.send_keys(:enter)
      expect(page).to have_product_card(count: 1)
      expect(page).to have_product_card(@c.link)
    end

    it "allows the purchaser to filter products by creator" do
      @another_creator = create(:user, username: nil, name: "Another user")
      create(:product, user: @another_creator, name: "Another Creator's Product C")
      create(:product, user: @another_creator, name: "Another Creator's Product D")
      another_a = create(:purchase, link: create(:product, user: @another_creator, name: "Another Creator's Product A", content_updated_at: 3.minutes.ago), purchaser: @user)
      another_b = create(:purchase, link: create(:product, user: @another_creator, name: "Another Creator's Product B", content_updated_at: 2.minutes.ago), purchaser: @user)
      # another_creator has 4 total products but just 2 purchased by this user to ensure counts reflect user purchases only
      Link.import(refresh: true, force: true)
      visit "/library"

      expect(page).to have_text("Showing 1-9 of 12")
      expect(find("label", text: @creator.name)).to have_text("(10)")
      expect(find("label", text: @another_creator.name)).to have_text("(2)")

      expect(find_field("All Creators", visible: false).checked?).to eq(true)
      find_and_click("label", text: @creator.name)
      expect(find_field("All Creators", visible: false).checked?).to eq(false)
      expect(find_field(@creator.name, visible: false).checked?).to eq(true)
      expect(find_field(@another_creator.name, visible: false).checked?).to eq(false)
      expect(page).to have_text("Showing 1-9 of 10")
      scroll_to find_product_card(@b.link)
      expect(page).to have_product_card(count: 10)
      expect_to_show_purchases_in_order([@j, @i, @h, @g, @f, @e, @d, @c, @b, @a])

      find_and_click("label", text: @creator.name)
      find_and_click("label", text: @another_creator.name)
      expect(find_field(@creator.name, visible: false).checked?).to eq(false)
      expect(find_field(@another_creator.name, visible: false).checked?).to eq(true)
      expect(find_field("All Creators", visible: false).checked?).to eq(false)
      expect(page).to have_text("Showing 1-2 of 2")
      expect(page).to have_product_card(count: 2)
      expect_to_show_purchases_in_order([another_b, another_a])

      find_and_click("label", text: "All Creators")
      expect(find_field("All Creators", visible: false).checked?).to eq(true)
      expect(find_field(@creator.name, visible: false).checked?).to eq(false)
      expect(find_field(@another_creator.name, visible: false).checked?).to eq(false)
      expect(page).to have_text("Showing 1-9 of 12")
      scroll_to find_product_card(@d.link)
      expect_to_show_purchases_in_order([another_b, another_a, @j, @i, @h, @g, @f, @e, @d, @c, @b, @a])
    end

    it "limits the creator filter list to 5 with a load more" do
      creator_2 = create(:named_user, name: "User 2")
      create(:purchase, link: create(:product, user: creator_2), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_2), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_2), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_2), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_2), purchaser: @user)

      creator_3 = create(:named_user, name: "User 3")
      create(:purchase, link: create(:product, user: creator_3), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_3), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_3), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_3), purchaser: @user)

      creator_4 = create(:named_user, name: "User 4")
      create(:purchase, link: create(:product, user: creator_4), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_4), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_4), purchaser: @user)

      creator_5 = create(:named_user, name: "User 5")
      create(:purchase, link: create(:product, user: creator_5), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_5), purchaser: @user)

      creator_6 = create(:named_user, name: "User 6")
      create(:purchase, link: create(:product, user: creator_6), purchaser: @user)

      Link.import(refresh: true, force: true)
      visit "/library"

      expect(page).to have_selector("label", text: @creator.name)
      expect(page).to have_selector("label", text: creator_2.name)
      expect(page).to have_selector("label", text: creator_3.name)
      expect(page).to have_selector("label", text: creator_4.name)
      expect(page).to have_selector("label", text: creator_5.name)
      expect(page).to_not have_selector("label", text: creator_6.name)

      find(".creator").click_on("Load more...")
      expect(page).to have_selector("label", text: creator_6.name)
      expect(find(".creator")).to_not have_text("Load more...")
    end

    it "sort the creator list by number of products" do
      creator_with_3_products = create(:named_user, name: "User 2")
      create(:purchase, link: create(:product, user: creator_with_3_products), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_with_3_products), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_with_3_products), purchaser: @user)

      creator_with_5_products = create(:named_user, name: "User 3")
      create(:purchase, link: create(:product, user: creator_with_5_products), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_with_5_products), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_with_5_products), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_with_5_products), purchaser: @user)
      create(:purchase, link: create(:product, user: creator_with_5_products), purchaser: @user)

      creator_with_1_product = create(:named_user, name: "User 4")
      create(:purchase, link: create(:product, user: creator_with_1_product), purchaser: @user)

      Link.import(refresh: true, force: true)
      visit "/library"

      expect(page).to have_selector("label:has(input[type=checkbox]):nth-of-type(2)", text: @creator.name, visible: false)
      expect(page).to have_selector("label:has(input[type=checkbox]):nth-of-type(3)", text: creator_with_5_products.name, visible: false)
      expect(page).to have_selector("label:has(input[type=checkbox]):nth-of-type(4)", text: creator_with_3_products.name, visible: false)
      expect(page).to have_selector("label:has(input[type=checkbox]):nth-of-type(5)", text: creator_with_1_product.name, visible: false)
    end
  end

  it "allow marking deleted by the buyer" do
    purchase = create(:purchase, purchaser: @user)
    Link.import(refresh: true, force: true)

    visit "/library"
    expect(page).to have_product_card(purchase.link)

    within find_product_card(purchase.link).hover do
      find_and_click "[aria-label='Open product action menu']"
      click_on "Delete"
    end
    expect(page).to have_text("Are you sure you want to delete #{purchase.link_name}?")
    click_on "Confirm"

    wait_for_ajax
    expect(page).to_not have_product_card(purchase.link)
  end

  it "shows new results upon scrolling to the bottom of the page" do
    products = []
    18.times do |n|
      product = create(:product, name: "Product #{n}")
      products << product
      create(:purchase, link: product, purchaser: @user)
    end

    Link.import(refresh: true, force: true)
    visit library_path

    expect(page).to have_text("Showing 1-9 of 18 products")
    9.times do |n|
      expect(page).to have_product_card(products[17 - n], exact_text: true)
    end
    9.times do |n|
      expect(page).to_not have_product_card(products[n], exact_text: true)
    end
    scroll_to find(:section, "9", section_element: :article)
    9.times do |n|
      expect(page).to have_product_card(products[n], exact_text: true)
    end
  end

  describe "bundle purchases" do
    let(:purchase) { create(:purchase, purchaser: @user, link: create(:product, :bundle)) }
    before do
      purchase.create_artifacts_and_send_receipt!
      create_list(:purchase, 8, purchaser: @user) do |purchase, i|
        purchase.link.update!(name: "Product #{i}")
      end
    end

    it "filters by bundle" do
      visit library_path
      (0..7).each do |i|
        expect(page).to have_section("Product #{i}", exact: true)
      end
      expect(page).to have_section("Bundle Product 2")
      expect(page).to_not have_section("Bundle Product 1")

      select_combo_box_option search: "Bundle", from: "Bundles"
      (0..7).each do |i|
        expect(page).to_not have_section("Product #{i}", exact: true)
      end

      within_section "Bundle Product 2", section_element: :article do
        expect(page).to have_link("Bundle Product 2", href: purchase.product_purchases.second.url_redirect.download_page_url)
      end
      within_section "Bundle Product 1", section_element: :article do
        expect(page).to have_link("Bundle Product 1", href: purchase.product_purchases.first.url_redirect.download_page_url)
      end
    end

    context "product was previously not a bundle" do
      before do
        purchase.update!(is_bundle_purchase: false)
      end

      it "shows the card for that product" do
        visit library_path

        search_field = find_field("Search products")
        search_field.fill_in with: "Bundle"
        search_field.native.send_keys(:enter)

        expect(page).to have_selector("[itemprop='name']", text: "Bundle", exact_text: true)
      end
    end
  end

  it "allows the application of multiple filters/sorts at once" do
    seller1 = create(:user, name: "Seller 1")
    seller2 = create(:user, name: "Seller 2")
    purchase1 = create(:purchase, purchaser: @user, link: create(:product, name: "Audiobook 1", user: seller1))
    purchase2 = create(:purchase, purchaser: @user, link: create(:product, name: "Course 1", user: seller1, content_updated_at: 1.day.ago))
    create(:purchase, purchaser: @user, link: create(:product, name: "Audiobook 2", user: seller2))
    create(:purchase, purchaser: @user, link: create(:product, name: "Course 2", user: seller2))

    visit library_path({ creators: seller1.external_id })

    expect(page).to have_checked_field("Seller 1")
    expect(page).to have_unchecked_field("Seller 2")
    expect(page).to have_unchecked_field("All Creators")

    expect_to_show_purchases_in_order([purchase1, purchase2])
    expect(page).to_not have_section("Course 2")
    expect(page).to_not have_section("Audiobook 2")

    select "Purchase Date", from: "Sort by"
    expect_to_show_purchases_in_order([purchase2, purchase1])
    expect(page).to_not have_section("Course 2")
    expect(page).to_not have_section("Audiobook 2")

    search_field = find_field("Search products")
    search_field.fill_in with: "Audiobook 1"
    search_field.native.send_keys(:enter)
    expect(page).to have_section("Audiobook 1")
    expect(page).to_not have_section("Course 1")
    expect(page).to_not have_section("Course 2")
    expect(page).to_not have_section("Audiobook 2")
  end

  it "shows navigation" do
    visit library_path

    expect(page).to have_tab_button("Purchases")
    expect(page).to have_tab_button("Saved")
    expect(page).to have_tab_button("Following")
  end

  context "follow_wishlists feature flag is disabled" do
    before { Feature.deactivate(:follow_wishlists) }

    it "shows only the wishlists tab" do
      visit wishlists_path
      expect(page).to have_tab_button("Wishlists")
      expect(page).not_to have_tab_button("Following")
    end
  end

  context "reviews_page feature flag is disabled" do
    it "does not show the reviews tab" do
      visit library_path
      expect(page).to_not have_link("Reviews")
    end
  end

  context "reviews_page feature flag is enabled" do
    let(:user) { create(:user) }

    before { Feature.activate_user(:reviews_page, user) }

    context "user has reviews" do
      let(:seller) { create(:user, name: "Seller") }
      let!(:reviews) do
        build_list(:product_review, 3) do |review, i|
          review.purchase.purchaser = user
          review.message = if i > 0 then "Message #{i}" else nil end
          review.update!(rating: i + 1)
          review.link.update!(user: seller, name: "Product #{i}")
          review.purchase.update!(seller:)
        end
      end
      let!(:thumbnail) { create(:thumbnail, product: reviews.first.link) }

      it "shows the user's reviews" do
        login_as user
        visit library_path

        select_tab "Reviews"
        expect(page.current_path).to eq(reviews_path)

        expect(page).to have_text("You've reviewed all your products!")
        expect(page).to have_link("Discover more", href: discover_url(host: DISCOVER_DOMAIN))

        within find("tr", text: "Product 0") do
          expect(page).to have_image(src: thumbnail.url)
          expect(page).to_not have_text('"')
          expect(page).to have_link("Product 0", href: reviews.first.link.long_url(recommended_by: "library"))
          expect(page).to have_link("Seller", href: reviews.first.link.user.profile_url)
          expect(page).to have_selector("[aria-label='1 star']")
          click_on "Edit"
          within "form" do
            expect(page).to have_radio_button("1 star", checked: true)
            (2..5).each do |i|
              expect(page).to have_radio_button("#{i} stars", checked: false)
            end
            click_on "Edit"
            choose "4 stars"
            fill_in "Want to leave a written review?", with: "Message 0"
            click_on "Update review"
          end
        end

        expect(page).to have_alert(text: "Review submitted successfully!")

        within find("tr", text: "Product 0") do
          within "form" do
            expect(page).to have_radio_button("1 star", checked: false)
            [2, 3, 5].each do |i|
              expect(page).to have_radio_button("#{i} stars", checked: false)
            end
            expect(page).to have_radio_button("4 stars", checked: true)
            expect(page).to have_text('"Message 0"')
          end
          click_on "Edit", match: :first
          expect(page).to have_selector("[aria-label='4 stars']")
          expect(page).to have_text('"Message 0"')
        end

        reviews.first.reload
        expect(reviews.first.rating).to eq(4)
        expect(reviews.first.message).to eq("Message 0")

        within find("tr", text: "Product 1") do
          # Products without a thumbnail use an inline placeholder
          expect(page).to have_image(src: "data:image/")
          expect(page).to have_text("Message 1")
          expect(page).to have_link("Product 1", href: reviews.second.link.long_url(recommended_by: "library"))
          expect(page).to have_link("Seller", href: reviews.second.link.user.profile_url)
          expect(page).to have_selector("[aria-label='2 stars']")
        end

        within find("tr", text: "Product 2") do
          expect(page).to have_image(src: "data:image/")
          expect(page).to have_text("Message 2")
          expect(page).to have_link("Product 2", href: reviews.third.link.long_url(recommended_by: "library"))
          expect(page).to have_link("Seller", href: reviews.third.link.user.profile_url)
          expect(page).to have_selector("[aria-label='3 stars']")
        end
      end
    end

    context "user has purchases awaiting review" do
      let!(:product1) { create(:product, name: "Product 1") }
      let!(:product2) { create(:product, name: "Product 2") }
      let!(:product3) { create(:product, name: "Product 3") }
      let!(:purchase1) { create(:purchase, purchaser: user, link: product1) }
      let!(:purchase2) { create(:purchase, purchaser: user, link: product2) }
      let!(:purchase3) { create(:purchase, purchaser: user, link: product3, created_at: 3.years.ago) }
      let!(:thumbnail) { create(:thumbnail, product: product1) }

      before { purchase3.seller.update!(disable_reviews_after_year: true) }

      it "shows review forms for purchases awaiting review" do
        login_as user
        visit library_path

        select_tab "Reviews"

        within "[role='listitem']", text: "Product 1" do
          expect(page).to have_image(src: thumbnail.url)
          expect(page).to have_link("Product 1", href: product1.long_url(recommended_by: "library"))
          expect(page).to have_link(product1.user.username, href: product1.user.profile_url)
          fill_in "Want to leave a written review?", with: "Message 1"
          choose "1 star"
          click_on "Post review"
        end
        expect(page).to have_alert(text: "Review submitted successfully!")
        expect(page).to_not have_selector("[role='listitem']", text: "Product 1")

        within "[role='listitem']", text: "Product 2" do
          expect(page).to have_field("Want to leave a written review?", focused: true)
          expect(page).to have_link("Product 2")
          choose "2 stars"
          click_on "Post review"
        end
        expect(page).to have_alert(text: "Review submitted successfully!")
        expect(page).to_not have_selector("[role='listitem']", text: "Product 2")

        expect(page).to_not have_selector("[role='listitem']", text: "Product 3")

        review1 = purchase1.reload.product_review
        expect(review1.rating).to eq(1)
        expect(review1.message).to eq("Message 1")

        review2 = purchase2.reload.product_review
        expect(review2.rating).to eq(2)
        expect(review2.message).to be_nil
      end
    end

    context "user has no reviews" do
      it "shows a placeholder" do
        login_as user
        visit reviews_path
        expect(page).to have_text("You haven't bought anything... yet!")
        expect(page).to have_text("Once you do, it'll show up here so you can review them.")
        expect(page).to have_link("Discover products", href: discover_url(host: DISCOVER_DOMAIN))
      end
    end
  end
end
