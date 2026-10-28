# frozen_string_literal: true

require("spec_helper")

describe("Product page waitlist", js: true, type: :system) do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, waitlist_enabled: true, purchase_disabled_at: Time.current) }

  it "lets a visitor join the waitlist in place of buying" do
    visit product.long_url

    expect(page).to have_selector("[role=status]", text: "Coming soon")
    expect(page).to have_text("#{seller.name} will email you when it launches. You'll also get their other updates.")
    expect(page).not_to have_text("This product is not currently for sale.")
    expect(page).not_to have_link("I want this!")
    expect(page).not_to have_text("Add to wishlist")

    fill_in "Email address", with: "visitor@example.com"
    expect do
      click_on "Notify me"
      expect(page).to have_selector("[role=status]", text: "You're on the list. Check your inbox to confirm.")
    end.to change { product.waitlist_entries.count }.by(1)

    expect(page).not_to have_button("Notify me")
    expect(product.waitlist_entries.last.follower.email).to eq("visitor@example.com")
  end

  it "keeps the purchase recovery link for past buyers" do
    visit product.long_url

    expect(page).to have_button("Notify me")
    expect(page).to have_text("Already bought this?")
    expect(page).to have_link("Get your download link")
  end

  it "shows an invalid email next to the field" do
    visit product.long_url

    fill_in "Email address", with: "visitor"
    click_on "Notify me"

    expect(find_field("Email address")[:"aria-invalid"]).to eq("true")
    expect(page).to have_text("Enter a valid email address.")
    expect(product.waitlist_entries.count).to eq(0)
  end

  it "shows the seller an inactive form and the waitlist count" do
    create(:waitlist_entry, product:, follower: create(:active_follower, user: seller))
    create(:waitlist_entry, product:, follower: create(:follower, user: seller))
    login_as(seller)

    visit product.long_url

    expect(page).to have_button("Notify me", disabled: true)
    expect(page).to have_text("Only you see this: 1 person is on the waitlist.")
  end

  it "keeps the not-for-sale notice when the waitlist is off" do
    product.update!(waitlist_enabled: false)

    visit product.long_url

    expect(page).to have_selector("[role=status]", text: "This product is not currently for sale.")
    expect(page).not_to have_button("Notify me")
  end

  it "shows no waitlist on a product that staff unpublished" do
    product.update!(is_unpublished_by_admin: true)

    visit product.long_url

    expect(page).to have_selector("[role=status]", text: "This product is not currently for sale.")
    expect(page).not_to have_button("Notify me")
  end

  it "shows the buy button once the product is published" do
    product.publish!

    visit product.long_url

    expect(page).to have_link("I want this!")
    expect(page).not_to have_button("Notify me")
  end
end
