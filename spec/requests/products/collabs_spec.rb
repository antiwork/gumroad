# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/products_navigation"
require "shared_examples/with_sorting_and_pagination"

describe "Collabs", type: :system, js: true do
  let(:user) { create(:user) }

  include_context "with switching account to user as admin for seller" do
    let(:seller) { user }
  end

  it_behaves_like "tab navigation on products page" do
    let(:url) { products_collabs_path }
  end

  context "when the user has collabs" do
    # User is a collaborator for two other sellers
    let(:seller_1) { create(:user) }
    let(:seller_1_collaborator) { create(:collaborator, seller: seller_1, affiliate_user: user) }

    let(:seller_2) { create(:user) }
    let(:seller_2_collaborator) { create(:collaborator, seller: seller_2, affiliate_user: user) }

    # Products

    # 1. Owned by user
    let!(:collab_1) { create(:product, :is_collab, user:, price_cents: 10_00, collaborator_cut: 30_00, created_at: 1.month.ago) }
    let!(:membership_collab_1) { create(:membership_product_with_preset_tiered_pricing, :is_collab, name: "My membership", user:, collaborator_cut: 50_00, created_at: 2.months.ago) }

    # 2. Owned by others
    let!(:collab_2) { create(:product, :is_collab, user: seller_1, price_cents: 20_00, collaborator_cut: 25_00, collaborator: seller_1_collaborator, created_at: 3.months.ago) }
    let!(:collab_3) { create(:product, :is_collab, user: seller_2, collaborator_cut: 50_00, collaborator: seller_2_collaborator, created_at: 4.months.ago) } # no purchases
    let!(:membership_collab_2) { create(:membership_product_with_preset_tiered_pricing, :is_collab, user: seller_2, collaborator_cut: 25_00, collaborator: seller_2_collaborator, created_at: 5.months.ago) }

    # Purchases
    let!(:collab_1_purchase_1) { create(:purchase_in_progress, seller: user, link: collab_1, affiliate: collab_1.collaborator) }
    let!(:collab_1_purchase_2) { create(:purchase_in_progress, seller: user, link: collab_1, affiliate: collab_1.collaborator) }
    let!(:collab_1_purchase_3) { create(:purchase_in_progress, seller: user, link: collab_1, affiliate: collab_1.collaborator) }
    let!(:collab_2_purchase_1) { create(:purchase_in_progress, seller: seller_1, link: collab_2, affiliate: collab_2.collaborator) }
    let!(:collab_2_purchase_2) { create(:purchase_in_progress, seller: seller_1, link: collab_2, affiliate: collab_2.collaborator) }
    let!(:membership_collab_1_purchase_1) do
      tier = membership_collab_1.tiers.first
      create(:membership_purchase, purchase_state: "in_progress",
                                   seller: user, link: membership_collab_1,
                                   price_cents: tier.prices.first.price_cents, # $3
                                   affiliate: membership_collab_1.collaborator, tier:)
    end
    let!(:membership_collab_1_purchase_2) do
      tier = membership_collab_1.tiers.last
      create(:membership_purchase, purchase_state: "in_progress",
                                   seller: user, link: membership_collab_1,
                                   price_cents: tier.prices.first.price_cents, # $5
                                   affiliate: membership_collab_1.collaborator, tier:)
    end
    let!(:membership_collab_2_purchase_1) do
      tier = membership_collab_2.tiers.last
      create(:membership_purchase, purchase_state: "in_progress",
                                   seller: seller_2, link: membership_collab_2,
                                   price_cents: tier.prices.first.price_cents, # $5
                                   affiliate: membership_collab_2.collaborator, tier:)
    end

    before do
      [
        collab_1_purchase_1,
        collab_1_purchase_2,
        collab_1_purchase_3,
        collab_2_purchase_1,
        collab_2_purchase_2,
        membership_collab_1_purchase_1,
        membership_collab_1_purchase_2,
        membership_collab_2_purchase_1,
      ].each do |p|
        p.process!
        p.update_balance_and_mark_successful!
      end

      index_model_records(Purchase)
      index_model_records(Link)
      index_model_records(Balance)
    end

    it "renders the correct stats and collab products", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      visit(products_collabs_path)

      within "[aria-label='Stats']" do
        within_section "Total revenue" do
          # collab 1: $21 = 3 * (10_00 * (1 - 0.3))
          # collab 2: $10 = 2 * $5
          # membership collab 1: $4 = 1 * $1.50 + 1 * $2.50
          # membership collab 2: $1.25 = 1 * $5 * 0.25
          # TOTAL: $21 + $10 + $4 + $1.25 = $36.25
          expect(page).to have_content "$36.25"
        end

        within_section "Customers" do
          expect(page).to have_content 5
        end

        within_section "Active members" do
          expect(page).to have_content 3
        end

        within_section "Collaborations" do
          expect(page).to have_content 5
        end
      end

      expect(page).to have_table("Memberships", with_rows: [
                                   { "Name" => membership_collab_1.name, "Price" => "$3+ a month", "Cut" => "50%", "Members" => "2", "Revenue" => "$4" },
                                   { "Name" => membership_collab_2.name, "Price" => "$3+ a month", "Cut" => "25%", "Members" => "1", "Revenue" => "$1.25" },
                                 ])

      expect(page).to have_table("Products", with_rows: [
                                   { "Name" => collab_1.name, "Price" => "$10", "Cut" => "70%", "Sales" => "3", "Revenue" => "$21" },
                                   { "Name" => collab_2.name, "Price" => "$20", "Cut" => "25%", "Sales" => "2", "Revenue" => "$10" },
                                   { "Name" => collab_3.name, "Price" => "$1", "Cut" => "50%", "Sales" => "0", "Revenue" => "$0" },
                                 ])

      within_table "Memberships" do
        within(:table_row, { "Name" => membership_collab_1.name }) do
          expect(page).to have_content "$4 /mo"
        end
        within(:table_row, { "Name" => membership_collab_2.name }) do
          expect(page).to have_content "$1.25 /mo"
        end
      end
    end

    # TODO (shan) Re-enable once server-side sorting properly works for all columns (may need additional tweaks)
    xdescribe "product sorting" do
      include_context "with products and memberships"

      it_behaves_like "a table with sorting", "Products" do
        before do
          visit(products_collabs_path)
        end

        let!(:default_order) { [collab_1, collab_2, collab_3] }
        let!(:columns) do
          {
            "Name" => [collab_1, collab_2, collab_3],
            "Price" => [collab_1, collab_2, collab_3],
            "Cut" => [collab_1, collab_2, collab_3],
            "Sales" => [collab_1, collab_2, collab_3],
            "Revenue" => [collab_1, collab_2, collab_3],
          }
        end
      end
    end

    xdescribe "membership sorting" do
      include_context "with products and memberships"

      it_behaves_like "a table with sorting", "Memberships" do
        before do
          visit(products_collabs_path)
        end

        let!(:default_order) { [collab_membership_1, collab_membership_2] }
        let!(:columns) do
          {
            "Name" => [collab_membership_1, collab_membership_2],
            "Price" => [collab_membership_1, collab_membership_2],
            "Cut" => [collab_membership_1, collab_membership_2],
            "Members" => [collab_membership_1, collab_membership_2],
            "Revenue" => [collab_membership_1, collab_membership_2],
          }
        end
      end
    end
  end

  context "when the user does not have collabs" do
    it "displays a placeholder message" do
      visit(products_collabs_path)

      expect(page).to have_text("Create your first collab!")
      expect(page).to have_link("Add a collab")
    end
  end
end
