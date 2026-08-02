# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Profile settings email confirmation", type: :system, js: true do
  let(:seller) { create(:user, email: "seller@example.com", username: "unconfirmedseller", confirmed_at: nil) }

  it "warns unconfirmed sellers before they edit an unsavable profile" do
    section = SellerProfileRichTextSection.create!(seller:, json_data: { "text" => {} })
    products = [create(:product, user: seller, name: "First product"), create(:product, user: seller, name: "Second product")]
    products_section = create(:seller_profile_products_section, seller:, shown_products: products.map(&:id))
    seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab 1", sections: [section.id, products_section.id] }] })

    login_as(seller)
    visit "/profile"

    expect(page).to have_alert(text: "Confirm your email address (seller@example.com) before you can save changes to your profile.")
    expect(page).to have_field("Name", disabled: true)
    find("[role=tab]", text: "Pages").click
    expect(page).to have_css("[contenteditable=false]")
    expect(page).not_to have_css("[contenteditable=true]")
    within("section[aria-label='Profile section editor']") do
      expect(page).not_to have_css("[data-drag-handle][draggable=true]")
      expect(page).not_to have_css("[data-page-grabbed][draggable=true]")
      within("[role=list][aria-label='Products']") do
        product_rows = all("[role=listitem]")
        expect(product_rows.map(&:text)).to eq(["First product", "Second product"])
        product_rows.first.find("[data-drag-handle]").drag_to(product_rows[1])
        expect(all("[role=listitem]").map(&:text)).to eq(["First product", "Second product"])
      end
    end
    click_button "Resend confirmation email"
    expect(page).to have_text("Confirmation email sent!")
  end

  it "leaves a confirmed seller's editor untouched" do
    login_as(create(:user, email: "confirmed@example.com", username: "confirmedseller"))
    visit "/profile"

    expect(page).to have_field("Name", disabled: false)
    expect(page).not_to have_text("before you can save changes to your profile")
  end

  it "gives the right refresh instruction when confirmation finishes in another tab" do
    login_as(seller)
    visit "/profile"
    seller.confirm

    click_button "Resend confirmation email"

    expect(page).to have_alert(text: "Your email address is already confirmed — refresh the page to continue.")
  end

  context "when the selected seller has no email address" do
    let(:seller) do
      create(:user, username: "emaillessseller").tap do |seller|
        seller.update_columns(email: nil, unconfirmed_email: nil, confirmed_at: nil)
      end
    end

    include_context "with switching account to user as admin for seller"

    it "shows a safe confirmation gate to a team member" do
      visit "/profile"

      expect(page).to have_alert(text: "Add and confirm an email address before you can save changes to your profile.")
      expect(page).to have_field("Name", disabled: true)
      expect(page).not_to have_button("Resend confirmation email")
    end
  end
end
