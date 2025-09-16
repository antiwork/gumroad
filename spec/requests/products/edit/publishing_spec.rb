# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit - Publishing Scenario", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller, payment_address: nil) }

  include_context "with switching account to user as admin for seller"

  describe("already published") do
    before do
      @product = create(:product_with_pdf_file, user: seller)
      @tag = create(:tag, name: "camel", humanized_name: "Bactrian 🐫s Have Two Humps")
      @product.tag!("camel")
      create(:product_review, purchase: create(:purchase, link: @product))
      create(:merchant_account_stripe_connect, user: seller)
      visit edit_link_path(@product.unique_permalink)
    end

    it("allows user to publish and unpublish product") do
      click_on "Unpublish"
      wait_for_ajax
      select_tab "Content"
      expect(page).to have_button("Publish and continue")
      expect(@product.reload.alive?).to be(false)
      click_on "Publish and continue"
      wait_for_ajax
      expect(page).to have_button("Unpublish")
      expect(@product.reload.alive?).to be(true)
    end

    it "allows creator to copy product url" do
      select_tab "Share"
      copy_button = find_button("Copy URL")
      copy_button.hover
      expect(copy_button).to have_tooltip(text: "Copy to Clipboard")

      copy_button.click
      expect(copy_button).to have_tooltip(text: "Copied!")

      # Hover somewhere else to trigger mouseout
      first("a").hover
      expect(copy_button).not_to have_tooltip(text: "Copy to Clipboard")
      expect(copy_button).not_to have_tooltip(text: "Copied!")

      copy_button.hover
      expect(copy_button).to have_tooltip(text: "Copy to Clipboard")
    end

    it "allows user to mark their product as adult" do
      wait_for_ajax
      select_tab "Share"
      check "This product contains content meant only for adults, including the preview"
      expect do
        save_change
      end.to change { @product.reload.is_adult }.to(true)
    end

    it "allows user to toggle product review display on their product" do
      wait_for_ajax
      select_tab "Share"
      uncheck "Display your product's 1-5 star rating to prospective customers"
      expect(page).not_to have_text("Ratings")
      expect do
        save_change
      end.to change { @product.reload.display_product_reviews }.to(false)

      check "Display your product's 1-5 star rating to prospective customers"
      expect(page).to have_text("Ratings")
      expect do
        save_change
      end.to change { @product.reload.display_product_reviews }.to(true)
    end
  end

  describe("unpublished") do
    before do
      @product = create(:product_with_pdf_file, user: seller, draft: false, purchase_disabled_at: Time.current)
    end

    it("does not allow publishing a product if no payout method is setup") do
      visit edit_link_path(@product.unique_permalink)
      click_on "Save and continue"
      wait_for_ajax
      click_on "Publish and continue"
      wait_for_ajax
      expect(page).to have_alert("You must connect at least one payment method before you can publish this product for sale.")
      expect(@product.reload.alive?).to be(false)
      expect(@product.published?).to be(false)
    end

    it("allows user to publish and unpublish product if a payout method is setup") do
      create(:merchant_account_stripe_connect, user: seller)

      visit edit_link_path(@product.unique_permalink)
      click_on "Save and continue"
      wait_for_ajax
      click_on "Publish and continue"
      wait_for_ajax
      expect(page).to have_button("Unpublish")
      expect(@product.reload.alive?).to be(true)
      expect(@product.published?).to be(true)
      click_on "Unpublish"
      wait_for_ajax
      expect(page).to have_button("Publish and continue")
      expect(@product.reload.alive?).to be(false)
      expect(@product.published?).to be(false)
    end

    context "Merchant migration enabled" do
      before do
        seller.check_merchant_account_is_linked = false
        seller.save!
        create(:ach_account_stripe_succeed, user: seller)
        vcr_turned_on do
          VCR.use_cassette("Product Edit Scenario-Merchant migration enabled", record: :once) do
            @merchant_account = create(:merchant_account_stripe, user: seller)
          end
        end

        Feature.activate_user(:merchant_migration, seller)
      end

      after do
        Feature.deactivate_user(:merchant_migration, seller)
      end

      it "allows publishing if new account and has a valid merchant account connected" do
        visit edit_link_path(@product.unique_permalink)

        select_tab "Content"
        click_on "Publish and continue"
        wait_for_ajax
        expect(page).to have_button("Unpublish")
        expect(@product.reload.alive?).to be(true)
        expect(@product.published?).to be(true)
      end
    end
  end
end
