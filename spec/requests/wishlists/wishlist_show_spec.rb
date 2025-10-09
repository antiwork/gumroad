# frozen_string_literal: true

require "spec_helper"
require "shared_examples/discover_layout"

describe "Wishlist show page", :js, type: :system do
  include Rails.application.routes.url_helpers

  let(:physical_product) { create(:product, :recommendable, name: "Quantity Product", price_cents: 1000, quantity_enabled: true) }
  let(:pwyw_product) { create(:product, name: "PWYW Product", price_cents: 1000, customizable_price: true) }
  let(:versioned_product) { create(:product_with_digital_versions, price_cents: 800, name: "Versioned Product") }
  let(:membership_product) do
    create(:membership_product_with_preset_tiered_pricing, :recommendable, name: "Membership Product", description: "A recurring membership", recurrence_price_values: [
             {
               "monthly": { enabled: true, price: 2 },
               "yearly": { enabled: true, price: 4 }
             },
             {
               "monthly": { enabled: true, price: 5 },
               "yearly": { enabled: true, price: 12 }
             }
           ])
  end
  let(:rental_product) { create(:product, name: "Rental Product", purchase_type: "buy_and_rent", price_cents: 500, rental_price_cents: 300) }
  let(:wishlist) { create(:wishlist, name: "My Wishlist", description: "My wishlist description", user: create(:user, name: "Wishlist User")) }

  before do
    create(:wishlist_product, wishlist:, product: physical_product, quantity: 2)
    create(:wishlist_product, wishlist:, product: pwyw_product)
    create(:wishlist_product, wishlist:, product: versioned_product, variant: versioned_product.variant_categories.first.variants.first)
    create(:wishlist_product, wishlist:, product: membership_product, recurrence: "yearly", variant: membership_product.variant_categories.first.variants.first)
    create(:wishlist_product, wishlist:, product: rental_product, rent: true)
  end

  it "shows products" do
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    expect(page).to have_text("My Wishlist")
    expect(page).to have_text("My wishlist description")
    expect(page).to have_link("Wishlist User", href: wishlist.user.profile_url)

    within find_product_card(physical_product) do
      expect(page).to have_selector("[itemprop='name']", text: "Quantity Product")
      expect(page).to have_selector("[itemprop='price']", text: "$10")
    end

    within find_product_card(membership_product) do
      expect(page).to have_selector("[itemprop='name']", text: "Membership Product - First Tier - Yearly")
    end

    within find_product_card(versioned_product) do
      expect(page).to have_selector("[itemprop='name']", text: "Versioned Product - Untitled 1")
    end

    find_product_card(membership_product).click
    expect(page).to have_text(membership_product.description)
  end

  it "supports buying single products with options prefilled" do
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    expect(page).to have_text("My Wishlist")

    within find_product_card(physical_product) do
      click_on "Add to cart"
    end

    within_cart_item(physical_product.name) do
      expect(page).to have_text("US$20")
      expect(page).to have_text("Qty: 2")
    end

    page.go_back

    within find_product_card(versioned_product) do
      click_on "Add to cart"
    end

    within_cart_item(versioned_product.name) do
      expect(page).to have_text("Version: Untitled 1")
    end

    page.go_back

    within find_product_card(membership_product) do
      click_on "Add to cart"
    end

    within_cart_item(membership_product.name) do
      expect(page).to have_text("Tier: First Tier")
      expect(page).to have_text("Membership: Yearly")
    end

    page.go_back

    within find_product_card(rental_product) do
      click_on "Add to cart"
    end

    within_cart_item(rental_product.name) do
      expect(page).to have_text("US$3")
    end
  end

  it "supports buying all products at once" do
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    click_link "Buy this wishlist"

    within_cart_item(physical_product.name) do
      expect(page).to have_text("US$20")
      expect(page).to have_text("Qty: 2")
    end

    within_cart_item(pwyw_product.name) do
      expect(page).to have_text("US$10")
    end

    within_cart_item(versioned_product.name) do
      expect(page).to have_text("Version: Untitled 1")
    end

    within_cart_item(membership_product.name) do
      expect(page).to have_text("Tier: First Tier")
      expect(page).to have_text("Membership: Yearly")
    end

    within_cart_item(rental_product.name) do
      expect(page).to have_text("US$3")
    end
  end

  it "sets recommended_by and links global affiliate" do
    wishlist.wishlist_products.where.not(product: [physical_product, pwyw_product]).each(&:mark_deleted!)
    physical_product.update!(allow_double_charges: true)

    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    click_link "Buy this wishlist"
    check_out(physical_product)

    expect(Purchase.where(link: physical_product).last).to have_attributes(
      recommended_by: RecommendationType::WISHLIST_RECOMMENDATION,
      affiliate_id: wishlist.user.global_affiliate.id,
    )
    expect(Purchase.where(link: pwyw_product).last).to have_attributes(
      recommended_by: RecommendationType::WISHLIST_RECOMMENDATION,
      affiliate_id: nil, # Not recommendable, so not eligible for global affiliate
    )

    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)
    click_link physical_product.name
    add_to_cart(physical_product)
    check_out(physical_product)

    expect(Purchase.last).to have_attributes(
      link: physical_product,
      recommended_by: RecommendationType::WISHLIST_RECOMMENDATION,
      affiliate_id: wishlist.user.global_affiliate.id,
    )

    login_as wishlist.user
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)
    click_link physical_product.name
    add_to_cart(physical_product)
    check_out(physical_product, email: wishlist.user.email, logged_in_user: wishlist.user)

    expect(Purchase.last).to have_attributes(
      link: physical_product,
      recommended_by: RecommendationType::WISHLIST_RECOMMENDATION,
      affiliate_id: nil, # Can't get global affiliate commission for your own wishlist
    )
  end

  it "prefills gift checkout" do
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    within find_product_card(membership_product) do
      click_on("Gift this product")
    end

    expect(page).to have_checked_field("Give as a gift")
    expect(page).to have_text("Wishlist User's email has been hidden for privacy purposes.")
    fill_in "Message", with: "Happy birthday!"

    check_out(membership_product, gift: { name: "Wishlist User" })
    expect(Purchase.last).to have_attributes(
      link: membership_product,
      recommended_by: RecommendationType::WISHLIST_RECOMMENDATION,
      affiliate_id: nil, # Can't get global affiliate commission for being gifted a product from your own wishlist
    )
    expect(Gift.last).to have_attributes(
      link: membership_product,
      gift_note: "Happy birthday!",
      is_recipient_hidden: true
    )
    expect(Gift.last.giftee_purchase).to have_attributes(
      email: wishlist.user.email,
      purchaser: wishlist.user,
      variant_attributes: [membership_product.variant_categories.first.variants.first],
      is_original_subscription_purchase: false
    )
    expect(Gift.last.gifter_purchase).to have_attributes(
      email: "test@gumroad.com",
      purchaser: nil,
      variant_attributes: [membership_product.variant_categories.first.variants.first],
      is_original_subscription_purchase: true
    )

    expect(Subscription.last).to have_attributes(
      user: wishlist.user,
      credit_card: nil
    )
  end

  it "clears existing cart items when doing gift checkout" do
    visit physical_product.long_url
    add_to_cart(physical_product)

    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    within find_product_card(versioned_product) do
      click_on("Gift this product")
    end

    expect(page).not_to have_text(physical_product.name)
    expect(page).to have_text(versioned_product.name)
    expect(page).to have_text("Total US$8", normalize_ws: true)
  end

  it "supports cancelling a gift checkout" do
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

    within find_product_card(versioned_product) do
      click_on("Gift this product")
    end

    click_button "Cancel gift option"
    click_button "Yes, reset"

    expect(page).to have_unchecked_field("Give as a gift")
    expect(page).not_to have_text("Wishlist User's email has been hidden for privacy purposes.")

    check "Give as a gift"

    expect(page).to have_field("Recipient email address")
    expect(page).not_to have_text("Wishlist User's email has been hidden for privacy purposes.")
  end

  context "when no products are purchasable" do
    before do
      wishlist.wishlist_products.each { |wishlist_product| wishlist_product.product.unpublish! }
    end

    it "disables the buy links" do
      visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

      buy_link = find_link("Buy this wishlist", inert: true)
      buy_link.hover
      expect(buy_link).to have_tooltip(text: "None of the products on this wishlist are available for purchase")
      expect(page).not_to have_link("Gift this product")
    end
  end

  it "supports editing your own wishlist" do
    visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)
    expect(page).not_to have_button("Edit")

    login_as wishlist.user
    refresh

    click_button "Edit"

    within_section wishlist.name, section_element: :aside do
      fill_in "Name", with: "New Wishlist Name"
      click_on "Close"
    end

    expect(page).to have_text("New Wishlist Name")

    click_button "Edit"

    within_section "New Wishlist Name", section_element: :aside do
      fill_in "Description", with: "Description Goes Here"

      click_on "Close"
    end

    within find_product_card(wishlist.wishlist_products.first.product) do
      expect(page).to have_text("$10")
    end

    within find_product_card(wishlist.wishlist_products.fourth.product) do
      expect(page).to have_text("$2 a month")
    end

    wishlist.wishlist_products.each do |wishlist_product|
      within find_product_card(wishlist_product.product) do
        click_on "Remove this product"
      end
    end

    expect(page).to have_text("Description Goes Here")
    expect(page).to have_text("Products from your wishlist will be displayed here")

    wishlist.wishlist_products.reload.each do |wishlist_product|
      expect(wishlist_product).to be_deleted
      expect(page).not_to have_text(wishlist_product.product.name)
    end
  end

  describe "discover layout" do
    let(:discover_url) { wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol, layout: Product::Layout::DISCOVER) }
    let(:non_discover_url) { wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol) }

    it_behaves_like "discover navigation when layout is discover"
  end

  describe "following wishlists" do
    let(:user) { create(:buyer_user) }

    it "redirects when not logged in" do
      url = wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)
      visit url
      click_button "Follow wishlist"
      expect(current_url).to eq(login_url(host: DOMAIN, next: url))
    end

    it "supports following and unfollowing wishlists" do
      login_as user
      visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)

      expect do
        click_button "Follow wishlist"
        expect(page).to have_alert(text: "You are now following My Wishlist!")
      end.to change(WishlistFollower, :count).from(0).to(1)

      wishlist_follower = WishlistFollower.last
      expect(wishlist_follower).to have_attributes(wishlist:, follower_user: user)

      click_button "Following"
      expect(page).to have_alert(text: "You are no longer following My Wishlist.")
      expect(wishlist_follower.reload).to be_deleted
    end

    it "does not show the button when the feature is disabled" do
      Feature.deactivate(:follow_wishlists)

      visit wishlist_url(wishlist.external_id_numeric, host: wishlist.user.subdomain_with_protocol)
      expect(page).not_to have_button("Follow wishlist")
    end
  end
end
