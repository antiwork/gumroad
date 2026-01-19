# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Checkout discounts page - upgrade discounts", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let!(:product1) { create(:product, name: "Product 1", user: seller, price_cents: 1000) }
  let!(:product2) { create(:product, name: "Product 2", user: seller, price_cents: 500) }
  let(:membership) { create(:membership_product_with_preset_tiered_pricing, name: "Membership", user: seller) }

  include_context "with switching account to user as admin for seller"

  describe "upgrade discounts" do
    let!(:required_product) { create(:product, name: "Required Product", user: seller, price_cents: 1000) }

    context "when feature is disabled" do
      it "does not display the upgrade discount toggle" do
        visit checkout_discounts_path
        click_on "New discount"

        expect(page).not_to have_text("Require ownership of another product (upgrade discount)")
      end
    end

    context "when feature is enabled" do
      before do
        Feature.activate_user(:upgrade_discounts, seller)
      end

      describe "creating an upgrade discount" do
        it "creates a discount with required products" do
          visit checkout_discounts_path
          click_on "New discount"

          fill_in "Name", with: "Upgrade Discount"
          fill_in "Discount code", with: "upgrade10"
          select_combo_box_option search: "Product 1", from: "Products"
          fill_in "Percentage", with: "10"

          check "Require ownership of another product (upgrade discount)"
          select_combo_box_option search: "Required Product", from: "Required products"

          click_on "Add discount"

          expect(page).to have_alert(text: "Successfully created discount!")
          within find(:table_row, { "Discount" => "Upgrade Discount" }) do
            expect(page).to have_text("10% off of Product 1")
          end

          offer_code = OfferCode.last
          expect(offer_code.name).to eq("Upgrade Discount")
          expect(offer_code.code).to eq("upgrade10")
          expect(offer_code.amount_percentage).to eq(10)
          expect(offer_code.required_product_ids).to eq([required_product.external_id])
        end

        it "creates a discount with required products and time-based tiers" do
          visit checkout_discounts_path
          click_on "New discount"

          fill_in "Name", with: "Tiered Upgrade"
          fill_in "Discount code", with: "tieredupgrade"
          select_combo_box_option search: "Product 1", from: "Products"
          fill_in "Percentage", with: "20"

          check "Require ownership of another product (upgrade discount)"
          select_combo_box_option search: "Required Product", from: "Required products"

          click_on "Add tier"
          within find("span.font-bold", text: "Tier 1").ancestor("div.rounded.border") do
            all("input[placeholder='0']").first.fill_in(with: "2")
            select "weeks", from: find("select")[:id]
            fill_in "Percentage", with: "50"
          end

          click_on "Add discount"

          expect(page).to have_alert(text: "Successfully created discount!")

          offer_code = OfferCode.last
          expect(offer_code.name).to eq("Tiered Upgrade")
          expect(offer_code.required_product_ids).to eq([required_product.external_id])
          expect(offer_code.minimum_quantity_discount_tiers).to eq([
                                                                     { "older_than_seconds" => 2.weeks.to_i, "older_than_unit" => "week", "discount" => { "type" => "percent", "value" => 50 } }
                                                                   ])
        end

        it "creates a discount with multiple discount tiers" do
          visit checkout_discounts_path
          click_on "New discount"

          fill_in "Name", with: "Multi-Tier Upgrade"
          fill_in "Discount code", with: "multitier"
          select_combo_box_option search: "Product 1", from: "Products"
          fill_in "Percentage", with: "10"

          check "Require ownership of another product (upgrade discount)"
          select_combo_box_option search: "Required Product", from: "Required products"

          click_on "Add tier"
          within find("span.font-bold", text: "Tier 1").ancestor("div.rounded.border") do
            all("input[placeholder='0']").first.fill_in(with: "1")
            select "weeks", from: find("select")[:id]
            fill_in "Percentage", with: "25"
          end

          click_on "Add tier"
          within find("span.font-bold", text: "Tier 2").ancestor("div.rounded.border") do
            all("input[placeholder='0']").first.fill_in(with: "1")
            select "months", from: find("select")[:id]
            fill_in "Percentage", with: "50"
          end

          click_on "Add discount"

          expect(page).to have_alert(text: "Successfully created discount!")

          offer_code = OfferCode.last
          expect(offer_code.minimum_quantity_discount_tiers.length).to eq(2)
        end

        it "removes a tier" do
          visit checkout_discounts_path
          click_on "New discount"

          fill_in "Name", with: "Tier Removal Test"
          fill_in "Discount code", with: "tierremove"
          select_combo_box_option search: "Product 1", from: "Products"
          fill_in "Percentage", with: "10"

          check "Require ownership of another product (upgrade discount)"
          select_combo_box_option search: "Required Product", from: "Required products"

          click_on "Add tier"
          expect(page).to have_text("Tier 1")

          click_button "Remove tier"
          expect(page).not_to have_text("Tier 1")

          click_on "Add discount"

          expect(page).to have_alert(text: "Successfully created discount!")

          offer_code = OfferCode.last
          expect(offer_code.minimum_quantity_discount_tiers).to be_blank
        end

        it "clears required products and tiers when unchecking the upgrade discount toggle" do
          visit checkout_discounts_path
          click_on "New discount"

          fill_in "Name", with: "Toggle Clear Test"
          fill_in "Discount code", with: "toggleclear"
          select_combo_box_option search: "Product 1", from: "Products"
          fill_in "Percentage", with: "10"

          check "Require ownership of another product (upgrade discount)"
          select_combo_box_option search: "Required Product", from: "Required products"
          click_on "Add tier"

          uncheck "Require ownership of another product (upgrade discount)"
          check "Require ownership of another product (upgrade discount)"

          expect(page).not_to have_text("Required Product")
          expect(page).not_to have_text("Tier 1")
        end
      end

      describe "editing an upgrade discount" do
        let!(:upgrade_offer_code) do
          create(:offer_code,
                 name: "Existing Upgrade",
                 code: "existingupgrade",
                 user: seller,
                 products: [product1],
                 amount_percentage: 15,
                 required_product_ids: [required_product.external_id],
                 minimum_quantity_discount_tiers: [
                   { "older_than_seconds" => 1.week.to_i, "older_than_unit" => "week", "discount" => { "type" => "percent", "value" => 30 } }
                 ]
          )
        end

        it "displays existing upgrade discount settings when editing" do
          visit checkout_discounts_path

          find(:table_row, { "Discount" => "Existing Upgrade" }).click
          within_modal "Existing Upgrade" do
            click_on "Edit"
          end

          expect(page).to have_checked_field("Require ownership of another product (upgrade discount)")
          expect(page).to have_text("Required Product")
          expect(page).to have_text("Tier 1")
        end

        it "updates an upgrade discount's required products" do
          other_required_product = create(:product, name: "Other Required", user: seller, price_cents: 500)

          visit checkout_discounts_path

          find(:table_row, { "Discount" => "Existing Upgrade" }).click
          within_modal "Existing Upgrade" do
            click_on "Edit"
          end

          select_combo_box_option search: "Other Required", from: "Required products"

          click_on "Save changes"

          expect(page).to have_alert(text: "Successfully updated discount!")

          upgrade_offer_code.reload
          expect(upgrade_offer_code.required_product_ids).to contain_exactly(required_product.external_id, other_required_product.external_id)
        end

        it "removes upgrade discount settings when unchecking the toggle" do
          visit checkout_discounts_path

          find(:table_row, { "Discount" => "Existing Upgrade" }).click
          within_modal "Existing Upgrade" do
            click_on "Edit"
          end

          uncheck "Require ownership of another product (upgrade discount)"

          click_on "Save changes"

          expect(page).to have_alert(text: "Successfully updated discount!")

          upgrade_offer_code.reload
          expect(upgrade_offer_code.required_product_ids).to eq([])
          expect(upgrade_offer_code.minimum_quantity_discount_tiers).to eq([])
        end
      end

      describe "displaying upgrade discount in drawer" do
        let!(:upgrade_offer_code) do
          create(:percentage_offer_code,
                 name: "Drawer Test",
                 code: "drawertest",
                 user: seller,
                 products: [product1],
                 amount_percentage: 20,
                 required_product_ids: [required_product.external_id]
          )
        end

        it "displays the upgrade discount badge or indicator in the drawer" do
          visit checkout_discounts_path

          find(:table_row, { "Discount" => "Drawer Test" }).click

          within_modal "Drawer Test" do
            within_section "Details" do
              expect(page).to have_text("Discount 20%", normalize_ws: true)
            end
          end
        end
      end

      describe "duplicating an upgrade discount" do
        let!(:upgrade_offer_code) do
          create(:percentage_offer_code,
                 name: "Duplicate Source",
                 code: "duplicatesource",
                 user: seller,
                 products: [product1],
                 amount_percentage: 25,
                 required_product_ids: [required_product.external_id],
                 minimum_quantity_discount_tiers: [
                   { "older_than_seconds" => 2.weeks.to_i, "older_than_unit" => "week", "discount" => { "type" => "percent", "value" => 40 } }
                 ]
          )
        end

        it "duplicates an upgrade discount with all settings preserved" do
          visit checkout_discounts_path

          find(:table_row, { "Discount" => "Duplicate Source" }).click
          within_modal "Duplicate Source" do
            click_on "Duplicate"
          end

          expect(page).to have_section("Create discount")
          expect(page).to have_field("Name", with: "Duplicate Source")
          expect(page).to have_field("Percentage", with: "25")
          expect(page).to have_checked_field("Require ownership of another product (upgrade discount)")
          expect(page).to have_text("Required Product")
          expect(page).to have_text("Tier 1")

          fill_in "Name", with: "Duplicated Upgrade"
          click_on "Add discount"

          expect(page).to have_alert(text: "Successfully created discount!")

          new_offer_code = OfferCode.last
          expect(new_offer_code.name).to eq("Duplicated Upgrade")
          expect(new_offer_code.required_product_ids).to eq([required_product.external_id])
          expect(new_offer_code.minimum_quantity_discount_tiers.length).to eq(1)
        end
      end
    end
  end
end
