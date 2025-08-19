# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Digital Versions", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product_with_pdf_files_with_size, user: seller) }

  include_context "with switching account to user as admin for seller"

  describe "digital versions" do
    before :each do
      @variant_category = product.variant_categories.new
      @variant_category.title = ""

      @variant_option = @variant_category.variants.new
      @variant_option.product_files << product.product_files.alive.first
      @variant_option.name = "First Product Files Grouping"
      @variant_option.save!
      @variant_option_two = create(:variant, :with_product_file, variant_category: @variant_category, name: "Basic Bundle")
    end

    it "allows to edit price of digital version option" do
      visit edit_link_path(product.unique_permalink)

      within version_rows[0] do
        within version_option_rows[0] do
          fill_in "Additional amount", with: "9"
        end
      end

      save_change

      in_preview do
        expect(page).to have_text("$10")
      end

      expect(product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 900
    end

    it "does not change variant category price when changing version option prices" do
      visit edit_link_path(product.unique_permalink)

      within_section "Pricing", match: :first do
        expect(page).to have_field("Amount", with: "1")
      end

      within version_rows[0] do
        within version_option_rows[0] do
          fill_in "Additional amount", with: "9"
        end
        within version_option_rows[1] do
          fill_in "Additional amount", with: "9"
        end
      end

      save_change

      within_section "Pricing", match: :first do
        expect(page).to have_field("Amount", with: "1")
      end

      visit short_link_path(product)

      within_section @variant_option.name, match: :first do
        expect(page).to have_text("$10")
      end
    end

    it "allows to re-order options" do
      visit edit_link_path(product.unique_permalink)
      page.scroll_to version_rows[0], align: :center

      click_on "Add version"
      within version_rows[0] do
        within version_option_rows[2] do
          fill_in "Version name", with: "Second version"
        end

        # Fix flaky spec when the banner component is present.
        page.scroll_to version_option_rows[0].find(".content"), align: :center

        version_option_rows[0].find("[aria-grabbed='false']").drag_to version_option_rows[1]
      end

      save_change

      expect(product.variant_categories.first.variants.reload.alive.in_order.pluck(:name)).to eq ["Basic Bundle", "First Product Files Grouping", "Second version"]
    end

    it "has a valid share URL" do
      visit edit_link_path(product.unique_permalink)

      within version_rows[0] do
        within version_option_rows[0] do
          new_window = window_opened_by { click_on("Share") }
          within_window new_window do
            expect(page).to have_text(product.name)
            expect(page).to have_text(product.user.name)
            expect(page).to have_radio_button(@variant_option.name)
          end
        end
      end
    end

    describe "deleting variant options" do
      before do
        create(:rich_content, entity: @variant_option, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is variant-level rich content 1", "type" => "text" }] }])
        create(:rich_content, entity: @variant_option_two, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is variant-level rich content 2", "type" => "text" }] }])
      end

      it "deletes a variant option without purchases with a confirmation dialog" do
        visit edit_link_path(product.unique_permalink)

        within version_rows[0] do
          within version_option_rows[0] do
            click_on "Remove version"
          end
        end

        within_modal "Remove First Product Files Grouping?" do
          expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
          click_on "No, cancel"
        end

        save_change
        refresh

        expect(@variant_option.reload).to be_present

        within version_rows[0] do
          within version_option_rows[0] do
            click_on "Remove version"
          end
        end

        within_modal "Remove First Product Files Grouping?" do
          expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
          click_on "Yes, remove"
        end

        save_change

        expect(@variant_option.reload).to be_deleted
      end

      it "deletes a variant option with only test purchases" do
        create(:purchase, link: product, variant_attributes: [@variant_option], purchaser: seller, purchase_state: "test_successful")
        visit edit_link_path(product.unique_permalink)

        within version_rows[0] do
          within version_option_rows[0] do
            click_on "Remove version"
          end
        end

        within_modal "Remove First Product Files Grouping?" do
          expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
          click_on "Yes, remove"
        end

        save_change

        expect(@variant_option.reload).to be_deleted
      end

      it "deletes a variant option with non-test purchases" do
        create(:purchase, link: product, variant_attributes: [@variant_option], purchase_state: "successful")
        visit edit_link_path(product.unique_permalink)

        within version_rows[0] do
          within version_option_rows[0] do
            click_on "Remove version"
          end
        end

        within_modal "Remove First Product Files Grouping?" do
          expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
          click_on "Yes, remove"
        end

        save_change

        expect(@variant_option.reload).to be_deleted
      end

      it "deletes all variant options of a variant category" do
        visit edit_link_path(product.unique_permalink)

        within_section "Versions" do
          within version_option_rows[0] do
            click_on "Remove version"
          end

          within_modal "Remove First Product Files Grouping?" do
            expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
            click_on "Yes, remove"
          end

          within version_option_rows[0] do
            click_on "Remove version"
          end

          within_modal "Remove Basic Bundle?" do
            expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
            click_on "Yes, remove"
          end
        end

        save_change

        expect(@variant_option.reload).to be_deleted
        expect(@variant_option_two.reload).to be_deleted
        expect(@variant_category.reload).to be_deleted

        within_section "Versions" do
          expect(page).to_not have_text("First Product Files Grouping")
          expect(page).to_not have_text("Basic Bundle")
          expect(page).to have_button("Add version")
        end
      end

      it "deletes all variant options even if variant category title is not empty" do
        @variant_category.update!(title: "My Product Files Groupings")
        visit edit_link_path(product.unique_permalink)

        within_section "Versions" do
          within version_option_rows[0] do
            click_on "Remove version"
          end

          within_modal "Remove First Product Files Grouping?" do
            expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
            click_on "Yes, remove"
          end

          within version_option_rows[0] do
            click_on "Remove version"
          end

          within_modal "Remove Basic Bundle?" do
            expect(page).to have_text("If you delete this version, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest version as a fallback. If no version exists, they will see the product-level content.")
            click_on "Yes, remove"
          end
        end

        save_change

        expect(@variant_option.reload).to be_deleted
        expect(@variant_option_two.reload).to be_deleted
        expect(@variant_category.reload).to be_deleted

        within_section "Versions" do
          expect(page).to_not have_text("First Product Files Grouping")
          expect(page).to_not have_text("Basic Bundle")
          expect(page).to have_button("Add version")
        end
      end
    end
  end
end
