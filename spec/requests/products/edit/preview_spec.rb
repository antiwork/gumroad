# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Previews", type: :system, js: true) do
  include ProductEditPageHelpers

  def nth(index, selector)
    el = all(selector)[index]
    raise "no elements found using selector '#{selector}'" unless el
    el
  end

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  include_context "with switching account to user as admin for seller"

  it "opens the full-screen preview only after the changes have been saved" do
    visit edit_link_path(product.unique_permalink)

    fill_in("You'll get...", with: "This should be saved automatically")

    new_window = window_opened_by do
      click_on "Preview"
    end
    within_window new_window do
      expect(page).to have_content "This should be saved automatically"
    end
  end

  it("instantly preview changes to product name and price") do
    visit edit_link_path(product.unique_permalink)

    in_preview do
      expect(page).to have_content product.name
      expect(page).to have_content "$#{product.price_cents / 100}"
    end

    fill_in("Name", with: "Slot machine")

    in_preview do
      expect(page).to have_content "Slot machine"
    end

    fill_in("Amount", with: 777)

    in_preview do
      expect(page).to have_content "$777"
    end

    fill_in("Amount", with: "888")
    check "Allow customers to pay what they want"

    in_preview do
      expect(page).to have_content "$888+"
    end
  end

  it("instantly previews variants") do
    visit edit_link_path(product.unique_permalink)

    click_on "Add version"
    within version_rows[0] do
      fill_in "Version name", with: "Version 1"
    end

    click_on "Add version"
    within version_rows[0] do
      within version_option_rows[1] do
        fill_in "Version name", with: "Version 2"
        fill_in "Maximum number of purchases", with: 0
      end
    end

    in_preview do
      within find(:radio_button, "Version 1") do
        expect(page).to have_text("$1")
        expect(page).to_not have_text("$1+")
        expect(page).to_not have_text("a month")
      end
      within find(:radio_button, "Version 2", disabled: true) do
        expect(page).to have_text("$1")
        expect(page).to_not have_text("$1+")
        expect(page).to_not have_text("a month")
        expect(page).to have_text("0 left")
      end
    end

    check "Hide sold out versions"
    in_preview do
      expect(page).to have_radio_button("Version 1", disabled: false)
      expect(page).to_not have_radio_button("Version 2")
    end
  end

  describe("sales count", :sidekiq_inline, :elasticsearch_wait_for_refresh) do
    it("instantly previews sales count on toggle change") do
      recreate_model_index(Purchase)

      product = create(:product, user: seller)
      create(:purchase, link: product, succeeded_at: 1.hour.ago)

      visit edit_link_path(product.unique_permalink)

      check "Publicly show the number of sales on your product page"
      in_preview do
        expect(page).to have_text("1 sale")
      end

      # Changes in setting should reflect in preview without browser reload
      uncheck "Publicly show the number of sales on your product page"
      in_preview do
        expect(page).not_to have_text("1 sale")
      end

      create(:purchase, link: product, succeeded_at: 1.hour.ago)
      visit edit_link_path(product.unique_permalink)

      # Sales count in preview should reflect the actual sales count
      check "Publicly show the number of sales on your product page"
      in_preview do
        expect(page).to have_text("2 sales")
      end
    end

    it("instantly previews supporters count on toggle change") do
      recreate_model_index(Purchase)

      product = create(:membership_product, user: seller)
      create(:membership_purchase, link: product, succeeded_at: 1.hour.ago, price_cents: 100)

      visit edit_link_path(product.unique_permalink)

      check "Publicly show the number of members on your product page"
      in_preview do
        expect(page).to have_text("1 member")
      end

      create(:membership_purchase, link: product, succeeded_at: 1.hour.ago, price_cents: 100)
      visit edit_link_path(product.unique_permalink)

      check "Publicly show the number of members on your product page"
      in_preview do
        expect(page).to have_text("2 members")
      end
    end
  end

  context "when initial price is $1 or above" do
    before do
      product.update!(price_cents: 100)
    end

    it "shows preview price tag at all times" do
      visit "/products/#{product.unique_permalink}/edit"
      in_preview do
        expect(page).to have_content "$1"
      end

      fill_in("Amount", with: "0")
      check "Allow customers to pay what they want"

      in_preview do
        expect(page).to have_content "$0+"
      end

      fill_in("Amount", with: "10")

      in_preview do
        expect(page).to have_content "$10"
      end
    end
  end

  context "when initial price is $0+" do
    before do
      product.update!(price_cents: 0, customizable_price: true)
    end

    it "does not hide the preview price tag when changed via PWYW setting" do
      visit "/products/#{product.unique_permalink}/edit"
      in_preview do
        expect(page).to have_content "$0+"
      end

      check "Allow customers to pay what they want"

      in_preview do
        expect(page).to have_content "$0+"
      end
    end
  end

  context "for a collab product" do
    let(:affiliate_user) { create(:user, name: "Jane Collab") }
    let!(:collaborator) { create(:collaborator, seller:, affiliate_user:, products: [product]) }

    shared_examples_for "displaying collaborator" do
      it "shows the collaborator's name if they should be shown as a co-creator" do
        visit edit_link_path(product.unique_permalink)

        in_preview do
          expect(page).to have_content affiliate_user.name
        end
      end

      it "does not show the collaborator's name if they should not be shown as a co-creator" do
        collaborator.update!(dont_show_as_co_creator: true)
        visit edit_link_path(product.unique_permalink)

        in_preview do
          expect(page).not_to have_content affiliate_user.name
        end
      end
    end

    it_behaves_like "displaying collaborator"

    context "that is a bundle" do
      let(:product) { create(:product, :bundle, user: seller) }

      it_behaves_like "displaying collaborator"
    end
  end
end
