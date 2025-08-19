# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Affiliate Signup Form", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  include_context "with switching account to user as admin for seller"

  context "when no published products are found" do
    it "displays the products not found message" do
      visit affiliates_path

      expect(page).to have_tab_button("Affiliate Signup Form", open: true)
      expect(page).to have_text("You need a published product to add affiliates.")
    end
  end

  context "when using the old form page" do
    it "redirects to the new affiliate signup form" do
      visit "/affiliate_requests/onboarding_form"

      expect(page).to have_current_path("/affiliates/onboarding")
      expect(page).to have_tab_button("Affiliate Signup Form", open: true)
      expect(page).to have_text("You need a published product to add affiliates.")
    end
  end

  context "when published products exist" do
    let!(:product_one) { create(:product, name: "Product 1", user: seller) }
    let!(:product_two) { create(:product, name: "Product 2", user: seller) }
    let!(:product_three) { create(:product, name: "Product 3", user: seller, purchase_disabled_at: DateTime.current) }
    let!(:product_four) { create(:product, name: "Product 4", user: seller) }
    let!(:archived_product) { create(:product, name: "Archived product", user: seller, archived: true) }
    let!(:not_enabled_archived_product) { create(:product, user: seller, name: "Not selected archived product", archived: true) }
    let!(:collab_product) { create(:product, :is_collab, name: "Collab product", user: seller) }
    let!(:self_service_collab_product) { create(:product, :is_collab, name: "Self service collab product", user: seller) }

    before do
      create(:self_service_affiliate_product, enabled: true, seller:, product: archived_product)
      create(:self_service_affiliate_product, enabled: false, seller:, product: self_service_collab_product) # enabled prior to conversion to a collab product
    end

    it "shows published, eligible products and allows enabling and disabling them" do
      visit "/affiliates/onboarding" # react route

      table_label = "Enable specific products"
      name_label = "Product"

      within_section "Affiliate link", section_element: :section do
        expect(page).to have_field("Your affiliate link", with: custom_domain_new_affiliate_request_url(host: seller.subdomain_with_protocol), readonly: true)
        expect(page).to_not have_alert(text: "You must enable and set up the commission for at least one product before sharing your affiliate link.")
      end
      within_table table_label do
        within(:table_row, { name_label => "Archived product" }) do
          uncheck "Enable product"
        end
      end
      within_section "Affiliate link", section_element: :section do
        expect(page).to have_field("Your affiliate link", with: custom_domain_new_affiliate_request_url(host: seller.subdomain_with_protocol), readonly: true, disabled: true)
        expect(page).to have_alert(text: "You must enable and set up the commission for at least one product before sharing your affiliate link.")
      end
      within_table table_label do
        within(:table_row, { name_label => "Archived product" }) do
          check "Enable product"
        end
      end

      within_table table_label do
        within(:table_row, { name_label => "Product 1" }) do
          expect(page).to have_field("Commission", disabled: true, with: nil)
          expect(page).to have_field("https://link.com", disabled: true, with: nil)

          check "Enable product"
          fill_in("Commission", with: "35")
          uncheck "Enable product"
        end

        within(:table_row, { name_label => "Product 2" }) do
          expect(page).to have_field("Commission", disabled: true, with: nil)
          expect(page).to have_field("https://link.com", disabled: true, with: nil)

          check "Enable product"
          fill_in("Commission", with: "20")
        end

        within(:table_row, { name_label => "Product 4" }) do
          expect(page).to have_field("Commission", disabled: true, with: nil)
          expect(page).to have_field("https://link.com", disabled: true, with: nil)

          check "Enable product"
          fill_in("Commission", with: "10")
          fill_in("https://link.com", with: "hello")
        end
        expect(page).to have_table_row({ name_label => archived_product.name })
        expect(page).not_to have_table_row({ name_label => not_enabled_archived_product.name })
      end

      # excludes ineligible products
      expect(page).not_to have_content collab_product.name
      expect(page).not_to have_content self_service_collab_product.name

      click_on "Save changes"
      expect(page).to have_alert(text: "There are some errors on the page. Please fix them and try again.")

      within_table table_label do
        within(:table_row, { name_label => "Product 4" }) do
          fill_in("https://link.com", with: "https://example.com")
        end
      end

      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      # Reload the page and verify that the changes actually persisted
      visit "/affiliates/onboarding" # react route

      within_table table_label do
        within(:table_row, { name_label => "Product 2" }) do
          expect(page).to have_field("Commission", with: "20")
          expect(page).to have_field("https://link.com", with: nil)
        end
        within(:table_row, { name_label => "Product 4" }) do
          expect(page).to have_field("Commission", with: "10")
          expect(page).to have_field("https://link.com", with: "https://example.com")
        end
        within(:table_row, { name_label => "Product 1" }) do
          expect(page).to have_field("Commission", disabled: true, with: "35")
          expect(page).to have_field("https://link.com", disabled: true, with: nil)
        end
      end
    end

    it "allows disabling the global affiliate program" do
      visit "/affiliates/onboarding"

      within_section "Gumroad Affiliate Program", section_element: :section do
        expect(page).to have_text("Being part of Gumroad Affiliate Program enables other creators to share your products in exchange for a 10% commission.")

        find_field("Opt out of the Gumroad Affiliate Program", checked: false).check
      end

      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      expect(seller.reload.disable_global_affiliate).to eq(true)

      refresh
      find_field("Opt out of the Gumroad Affiliate Program", checked: true).uncheck
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      expect(seller.reload.disable_global_affiliate).to eq(false)
    end
  end

  context "creating an affiliate from the onboarding form" do
    let!(:product) { create(:product, name: "Test Product", user: seller) }

    it "creates the first affiliate, initiating the form from the onboarding page" do
      affiliate_user = create(:named_user)
      expect do
        visit "/affiliates/onboarding" # react route
        wait_for_ajax

        click_on("Add affiliate")
        expect(page).to have_text("New Affiliate")

        fill_in("Email", with: affiliate_user.email)
        within :table_row, { "Product" => "Test Product" } do
          check "Enable product"
          fill_in("Commission", with: "10")
          fill_in("https://link.com", with: "http://google.com/")
        end
        click_on("Add affiliate")

        within(:table_row, { "Name" => affiliate_user.name, "Products" => product.name, "Commission" => "10%" }) do
          expect(page).to have_command("Edit")
          expect(page).to have_command("Delete")
        end
      end.to change { seller.direct_affiliates.count }.by(1)
    end
  end
end
