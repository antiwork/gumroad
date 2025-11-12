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
end
