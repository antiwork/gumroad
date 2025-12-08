# frozen_string_literal: true

require "spec_helper"

describe "Admin::PurchasesController Scenario", type: :system, js: true do
  let(:admin) { create(:admin_user) }
  let(:purchase) { create(:purchase, purchaser: create(:user), is_deleted_by_buyer: true) }

  before do
    login_as(admin)
  end

  describe "undelete functionality" do
    it "shows undelete button for deleted purchases" do
      visit admin_purchase_path(purchase.id)

      expect(page).to have_button("Undelete")
    end

    it "does not show undelete button for non-deleted purchases" do
      purchase.update!(is_deleted_by_buyer: false)
      visit admin_purchase_path(purchase.id)

      expect(page).not_to have_button("Undelete")
    end

    it "allows undeleting purchase" do
      expect(purchase.reload.is_deleted_by_buyer).to be(true)

      visit admin_purchase_path(purchase.id)
      click_on "Undelete"
      accept_browser_dialog
      wait_for_ajax

      expect(purchase.reload.is_deleted_by_buyer).to be(false)
      expect(page).to have_button("Undeleted!")
    end
  end

  describe "resend receipt functionality" do
    let(:new_email) { "newemail@example.com" }

    before do
      purchase.update!(is_deleted_by_buyer: false)
    end

    def resend_receipt(email: nil)
      fill_in "resend_receipt[email_address]", with: email
      click_on "Send"
      accept_browser_dialog
      wait_for_ajax
    end

    it "successfully resends receipt with a valid email" do
      visit admin_purchase_path(purchase.id)
      find("summary", text: "Resend receipt").click

      # With the original email
      resend_receipt
      expect(page).to have_alert(text: "Receipt sent successfully.")
      expect(purchase.reload.email).to eq(purchase.email)

      # With a new email
      new_email = "newemail@example.com"
      resend_receipt(email: new_email)
      expect(page).to have_alert(text: "Receipt sent successfully.")
      expect(purchase.reload.email).to eq(new_email)

      # With an invalid email, fails with validation error
      error = ActiveRecord::RecordInvalid.new(purchase)
      allow(error).to receive(:message).and_return("Validation failed: Email is invalid")
      allow_any_instance_of(Purchase).to receive(:save!).and_raise(error)
      resend_receipt(email: "test@example.com")
      expect(page).to have_alert(text: "Validation failed: Email is invalid")
      expect(purchase.reload.email).to eq(purchase.email)
    end
  end

  describe "tip display" do
    it "shows tip amount correctly when purchase has a tip" do
      create(:tip, purchase: purchase, value_usd_cents: 500)

      visit admin_purchase_path(purchase.id)

      expect(page).to have_content("Tip $5", normalize_ws: true)
    end
  end

  it "shows custom fields" do
    create(:purchase_custom_field, purchase:)
    create(:purchase_custom_field, purchase:, name: "Boolean field", field_type: CustomField::TYPE_CHECKBOX, value: true)

    visit admin_purchase_path(purchase.id)

    expect(page).to have_content("Custom field custom field value (custom field) Boolean field true (custom field)", normalize_ws: true)
  end

  describe "update giftee email functionality" do
    let(:giftee_email) { "original_giftee@example.com" }
    let(:new_giftee_email) { "new_giftee@example.com" }
    let(:gifter_purchase) { create(:purchase, :gift_sender) }
    let(:giftee_purchase) { create(:purchase, :gift_receiver, email: giftee_email) }
    let!(:gift) { create(:gift, gifter_email: gifter_purchase.email, giftee_email: giftee_email, gifter_purchase: gifter_purchase, giftee_purchase: giftee_purchase) }

    it "allows updating giftee email for a gift purchase" do
      visit admin_purchase_path(gifter_purchase.id)
      select_disclosure "Edit giftee email" do
        fill_in "giftee_email", with: new_giftee_email
        click_on "Update"
      end
      expect(page).to have_alert(text: "Successfully updated the giftee email.")
      expect(gift.reload.giftee_email).to eq(new_giftee_email)
      expect(giftee_purchase.reload.email).to eq(new_giftee_email)
    end
  end

  describe "discount display" do
    it "displays discount code when offer_code has a code" do
      product = create(:product, price_cents: 1000)
      offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 20, code: "SAVE20")
      purchase = create(:purchase, link: product)
      offer_code.purchases << purchase

      visit admin_purchase_path(purchase)

      expect(page).to have_text("Discount code")
      expect(page).to have_text("SAVE20 for 20% off")
    end

    it "displays discount without code when offer_code.code is nil" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1000)
      upsell_offer_code = OfferCode.new(
        user: seller,
        code: nil,
        amount_percentage: 15,
        universal: false
      )
      upsell_offer_code.products << product
      upsell_offer_code.save!(validate: false)
      create(:upsell, seller: seller, product: product, cross_sell: true, offer_code: upsell_offer_code)
      purchase = create(:purchase, link: product)
      upsell_offer_code.purchases << purchase

      visit admin_purchase_path(purchase)

      expect(page).not_to have_text("Discount code")
      expect(page).to have_text("Discount")
      expect(page).to have_text("15% off")
    end
  end
end
