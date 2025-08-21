# frozen_string_literal: true

require "spec_helper"

describe "Collaborators", type: :system, js: true do
  describe "seller view" do
    let(:seller) { create(:user) }
    before { login_as seller }

    context "viewing collaborators" do
      context "when there are none" do
        it "displays a placeholder message" do
          visit collaborators_path

          expect(page).to have_selector("h1", text: "Collaborators")
          expect(page).to have_selector("h2", text: "No collaborators yet")
          expect(page).to have_selector("h4", text: "Share your revenue with the people who helped create your products.")
        end
      end

      context "when there are some" do
        let(:product_one) { create(:product, user: seller, name: "First product") }
        let(:product_two) { create(:product, user: seller, name: "Second product") }
        let(:product_three) { create(:product, user: seller, name: "Third product") }
        let(:product_four) { create(:product, user: seller, name: "Fourth product") }
        let(:product_five) { create(:product, user: seller, name: "Fifth product") }
        let!(:collaborator_one) do
          co = create(:collaborator, seller:)
          co.product_affiliates.create!(product: product_one, affiliate_basis_points: 50_00)
          co.product_affiliates.create!(product: product_two, affiliate_basis_points: 35_00)
          co
        end
        let!(:collaborator_two) do
          affiliate_user = create(:user, payment_address: nil)
          create(:collaborator, seller:, affiliate_user:)
        end
        let!(:collaborator_three) { create(:collaborator, seller:, products: [product_three,]) }
        let!(:collaborator_four) do
          create(:collaborator, :with_pending_invitation, seller:, products: [product_four, product_five])
        end

        it "displays a list of collaborators" do
          visit collaborators_path

          [
            {
              "Name" => collaborator_one.affiliate_user.username,
              "Products" => "2 products",
              "Cut" => "35% - 50%",
              "Status" => "Accepted"
            },
            {
              "Name" => collaborator_two.affiliate_user.username,
              "Products" => "None",
              "Cut" => "30%",
              "Status" => "Accepted"
            },
            {
              "Name" => collaborator_three.affiliate_user.username,
              "Products" => product_three.name,
              "Cut" => "30%",
              "Status" => "Accepted"
            },
            {
              "Name" => collaborator_four.affiliate_user.username,
              "Products" => "2 products",
              "Cut" => "30%",
              "Status" => "Pending"
            },
          ].each do |row|
            expect(page).to have_table_row(row)
          end
        end



        it "displays details about a collaborator" do
          create(:merchant_account, user: collaborator_one.affiliate_user)
          create(:ach_account, user: collaborator_one.affiliate_user, stripe_bank_account_id: "ba_bankaccountid")

          visit collaborators_path

          find(:table_row, { "Name" => collaborator_one.affiliate_user.username, "Products" => "2 products", "Cut" => "35% - 50%" }).click
          within_section collaborator_one.affiliate_user.name, section_element: :aside do
            expect(page).to have_text(collaborator_one.affiliate_user.email)
            expect(page).to have_text(product_one.name)
            expect(page).to have_text(product_two.name)
            expect(page).to have_text("35%")
            expect(page).to have_text("50%")
            expect(page).to have_link("Edit")
            expect(page).to have_button("Remove")
            expect(page).not_to have_text("Collaborators won't receive their cut until they set up a payout account in their Gumroad settings.")
          end

          find(:table_row, { "Name" => collaborator_two.affiliate_user.username, "Products" => "None", "Cut" => "30%" }).click
          within_section collaborator_two.affiliate_user.name, section_element: :aside do
            expect(page).to have_text(collaborator_two.affiliate_user.email)
            expect(page).to have_link("Edit")
            expect(page).to have_button("Remove")
            expect(page).to have_text("Collaborators won't receive their cut until they set up a payout account in their Gumroad settings.")
          end
        end
      end
    end

    context "adding a collaborator" do
      let!(:product1) { create(:product, user: seller, name: "First product") }
      let!(:product2) { create(:product, user: seller, name: "Second product") }
      let!(:product3) do
        create(:product, user: seller, name: "Third product").tap do |product|
          create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
        end
      end
      let!(:product4) do
        create(:product, user: seller, name: "Fourth product").tap do |product|
          create(:product_affiliate, product:, affiliate: create(:collaborator, seller:))
        end
      end
      let!(:product5) { create(:product, user: seller, name: "Fifth product", purchase_disabled_at: Time.current) }
      let!(:collaborating_user) { create(:user) }

      it "adds a collaborator for all visible products" do
        expect do
          visit collaborators_path
          click_on "Add collaborator"

          fill_in "email", with: "#{collaborating_user.email}  " # test trimming email
          uncheck "Show as co-creator", checked: true
          click_on "Add collaborator"

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path "/collaborators"
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { ProductAffiliate.count }.from(2).to(5)

        collaborator = seller.collaborators.last
        expect(collaborator.apply_to_all_products).to eq true
        expect(collaborator.affiliate_percentage).to eq 50
        expect(collaborator.dont_show_as_co_creator).to eq true
        expect(collaborator.products).to match_array [product1, product2, product3]

        [product1, product2, product3].each do |product|
          expect(product.reload.is_collab).to eq(true)
          pa = collaborator.product_affiliates.find_by(product:)
          expect(pa.affiliate_percentage).to eq 50
        end

        expect(page).to have_table_row(
          {
            "Name" => collaborator.affiliate_user.username,
            "Products" => "3 products",
            "Cut" => "50%",
            "Status" => "Pending"
          }
        )
      end

      it "allows enabling different products with different cuts" do
        expect do
          visit "/collaborators/new"

          fill_in "email", with: collaborating_user.email
          uncheck "All products"
          within find(:table_row, { "Product" => product1.name }) do
            check product1.name
            fill_in "Percentage", with: 40
            uncheck "Show as co-creator", checked: true
          end
          within find(:table_row, { "Product" => product3.name }) do
            check product3.name
            fill_in "Percentage", with: 10
          end

          click_on "Add collaborator"

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path "/collaborators"
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { ProductAffiliate.count }.from(2).to(4)

        collaborator = seller.collaborators.last
        expect(collaborator.affiliate_user).to eq collaborating_user
        expect(collaborator.apply_to_all_products).to eq false
        expect(collaborator.affiliate_percentage).to eq 50
        expect(collaborator.dont_show_as_co_creator).to eq false

        pa = collaborator.product_affiliates.find_by(product: product1)
        expect(pa.affiliate_percentage).to eq 40
        expect(pa.dont_show_as_co_creator).to eq true

        pa = collaborator.product_affiliates.find_by(product: product3)
        expect(pa.affiliate_percentage).to eq 10
        expect(pa.dont_show_as_co_creator).to eq false

        expect(collaborator.product_affiliates.exists?(product: product2)).to eq false
      end

      it "does not allow creating a collaborator with invalid parameters" do
        visit "/collaborators/new"

        # invalid email
        fill_in "email", with: "foo"
        click_on "Add collaborator"
        expect(page).to have_alert(text: "Please enter a valid email")

        # no user with that email
        fill_in "email", with: "foo@example.com"
        click_on "Add collaborator"
        expect(page).to have_alert(text: "The email address isn't associated with a Gumroad account.")

        # no products selected
        fill_in "email", with: collaborating_user.email
        [product1, product2, product3].each do |product|
          within find(:table_row, { "Product" => product.name }) do
            uncheck product.name
          end
        end
        click_on "Add collaborator"
        expect(page).to have_alert(text: "At least one product must be selected")

        # invalid default percent commission
        within find(:table_row, { "Product" => product1.name }) do
          check product1.name
        end
        within find(:table_row, { "Product" => "All products" }) do
          fill_in "Percentage", with: 75
        end
        click_on "Add collaborator"
        within find(:table_row, { "Product" => "All products" }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Collaborator cut must be 50% or less")

        # invalid product percent commission
        uncheck "All products"
        within find(:table_row, { "Product" => product1.name }) do
          check product1.name
          fill_in "Percentage", with: 75
        end
        click_on "Add collaborator"
        within find(:table_row, { "Product" => product1.name }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Collaborator cut must be 50% or less")
        within find(:table_row, { "Product" => product1.name }) do
          fill_in "Percentage", with: 40
          expect(page).not_to have_selector("fieldset.danger")
          fill_in "Percentage", with: 0
        end
        click_on "Add collaborator"
        within find(:table_row, { "Product" => product1.name }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Collaborator cut must be 50% or less")

        # missing default percent commission
        check "All products"
        within find(:table_row, { "Product" => "All products" }) do
          fill_in "Percentage", with: ""
        end
        click_on "Add collaborator"
        within find(:table_row, { "Product" => "All products" }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Collaborator cut must be 50% or less")

        # missing product percent commission
        uncheck "All products"
        within find(:table_row, { "Product" => product1.name }) do
          check product1.name
          fill_in "Percentage", with: ""
          expect(page).to have_field("Percentage", placeholder: "50") # shows the default value as a placeholder
        end
        click_on "Add collaborator"
        within find(:table_row, { "Product" => product1.name }) do
          expect(page).to have_field("Percentage", placeholder: "50") # shows the default value as a placeholder
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Collaborator cut must be 50% or less")
      end

      it "does not allow adding a collaborator for ineligible products but does for unpublished products" do
        invisible_product = create(:product, user: seller, name: "Deleted product", deleted_at: 1.day.ago)

        visit "/collaborators/new"
        expect(page).not_to have_content invisible_product.name
        expect(page).not_to have_content product4.name
        expect(page).not_to have_content product5.name

        check "Show unpublished and ineligible products"
        expect(page).to have_content product4.name
        expect(page).to have_content product5.name

        within find(:table_row, { "Product" => product4.name }) do
          expect(page).to have_unchecked_field(product4.name, disabled: true)
        end
        within find(:table_row, { "Product" => product5.name }) do
          expect(page).to have_checked_field(product5.name)
        end

        fill_in "email", with: collaborating_user.email
        uncheck "All products"

        within find(:table_row, { "Product" => product2.name }) do
          check product2.name
        end
        within find(:table_row, { "Product" => product3.name }) do
          check product3.name
        end
        within find(:table_row, { "Product" => product4.name }) do
          expect(page).to have_unchecked_field(product4.name, disabled: true)
          expect(page).to have_content "Already has a collaborator"
        end
        within find(:table_row, { "Product" => product5.name }) do
          check product5.name
        end

        expect do
          click_on "Add collaborator"

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path "/collaborators"
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { ProductAffiliate.count }.from(2).to(5)

        collaborator = seller.collaborators.last
        expect(collaborator.products).to match_array [product2, product3, product5]

        visit collaborators_path
        within :table_row, { "Name" => collaborator.affiliate_user.display_name } do
          click_on "Edit"
        end

        expect(page).to have_checked_field("Show unpublished and ineligible products")
        within find(:table_row, { "Product" => product5.name }) do
          expect(page).to have_checked_field(product5.name)
        end
      end

      it "disables affiliates when adding a collaborator to a product with affiliates" do
        affiliate = create(:direct_affiliate, seller:)
        affiliated_products = (1..12).map { |i| create(:product, user: seller, name: "Number #{i} affiliate product") }
        affiliate.products = affiliated_products

        visit "/collaborators/new"
        expect do
          fill_in "email", with: collaborating_user.email

          affiliated_products.each do |product|
            within find(:table_row, { "Product" => product.name }) do
              expect(page).to have_content "Selecting this product will remove all its affiliates."
            end
          end

          click_on "Add collaborator"

          expect(page).to have_modal("Remove affiliates?")
          within_modal("Remove affiliates?") do
            expect(page).to have_text("Affiliates will be removed from the following products:")
            affiliated_products.first(10).each do |product|
              expect(page).to have_text(product.name)
            end
            affiliated_products.last(2).each do |product|
              expect(page).not_to have_text(product.name)
            end
            expect(page).to have_text("and 2 others.")
            click_on "No, cancel"
          end
          expect(page).not_to have_modal("Remove affiliates?")

          click_on "Add collaborator"
          expect(page).to have_modal("Remove affiliates?")
          within_modal("Remove affiliates?") do
            click_on "Yes, continue"
          end

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path "/collaborators"

          collaborator = seller.collaborators.last
          expect(collaborator.products).to match_array([product1, product2, product3] + affiliated_products)
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { affiliate.reload.products.count }.from(12).to(0)
      end

      it "does not allow adding a collaborator if creator is using a Brazilian Stripe Connect account" do
        brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
        seller.update!(check_merchant_account_is_linked: true)
        expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

        visit collaborators_path

        link = find_link("Add collaborator", inert: true)
        link.hover
        expect(link).to have_tooltip(text: "Collaborators with Brazilian Stripe accounts are not supported.")

        visit "/collaborators/new"

        button = find_button("Add collaborator", disabled: true)
        button.hover
        expect(button).to have_tooltip(text: "Collaborators with Brazilian Stripe accounts are not supported.")
      end
    end

    it "allows deleting a collaborator" do
      collaborators = create_list(:collaborator, 2, seller:)
      product = create(:product, user: seller, is_collab: true)
      create(:product_affiliate, affiliate: collaborators.first, product:)

      visit collaborators_path
      within find(:table_row, { "Name" => collaborators.first.affiliate_user.username }) do
        click_on "Delete"
      end
      expect(page).to have_alert(text: "The collaborator was removed successfully.")
      expect(collaborators.first.reload.deleted_at).to be_present
      expect(product.reload.is_collab).to eq false
      expect(page).to_not have_table_row({ "Name" => collaborators.first.affiliate_user.username })

      find(:table_row, { "Name" => collaborators.second.affiliate_user.username }).click
      within_section collaborators.second.affiliate_user.username, section_element: :aside do
        click_on "Remove"
      end
      wait_for_ajax
      expect(page).to have_alert(text: "The collaborator was removed successfully.")
      expect(collaborators.second.reload.deleted_at).to be_present
      expect(page).to_not have_table_row({ "Name" => collaborators.second.affiliate_user.username })
    end

    context "editing a collaborator" do
      let!(:product1) { create(:product, user: seller, name: "First product") }
      let!(:product2) { create(:product, user: seller, name: "Second product") }
      let!(:product3) { create(:product, user: seller, name: "Third product") }
      let!(:product4) { create(:product, user: seller, name: "Fourth product").tap { |product| create(:direct_affiliate, products: [product]) } }
      let!(:ineligible_product) { create(:product, user: seller, name: "Ineligible product").tap { |product| create(:collaborator, products: [product]) } }
      let!(:collaborator) { create(:collaborator, seller:, apply_to_all_products: true, affiliate_basis_points: 40_00, products: [product1, product2], dont_show_as_co_creator: true) }

      before do
        collaborator.product_affiliates.first.update!(dont_show_as_co_creator: true)
      end

      it "allows editing a collaborator" do
        expect do
          visit collaborators_path
          within :table_row, { "Name" => collaborator.affiliate_user.display_name } do
            click_on "Edit"
          end

          expect(page).to have_text collaborator.affiliate_user.display_name

          # edit default commission
          within find(:table_row, { "Product" => "All products" }) do
            expect(page).to have_checked_field("All products")
            fill_in "Percentage", with: 30
          end

          # disable product 1
          within find(:table_row, { "Product" => product1.name }) do
            uncheck product1.name
          end

          # enable individual cuts
          uncheck "All products"

          # show as co-creator & edit commission for product 2
          within find(:table_row, { "Product" => product2.name }) do
            check product2.name
            check "Show as co-creator", checked: false
            fill_in "Percentage", with: 25
          end

          # enable products 3 + 4
          within find(:table_row, { "Product" => product3.name }) do
            check product3.name
          end
          within find(:table_row, { "Product" => product4.name }) do
            expect(page).to have_content "Selecting this product will remove all its affiliates."
            check product4.name
            fill_in "Percentage", with: 45
          end

          check "Show unpublished and ineligible products"
          # cannot select ineligible product
          within find(:table_row, { "Product" => ineligible_product.name }) do
            have_unchecked_field(ineligible_product.name, disabled: true)
            expect(page).to have_content "Already has a collaborator"
          end

          click_on "Save changes"

          expect(page).to have_modal("Remove affiliates?")
          within_modal("Remove affiliates?") do
            expect(page).to have_text("Affiliates will be removed from the following products:")
            expect(page).to have_text(product4.name)
            click_on "Close"
          end
          expect(page).not_to have_modal("Remove affiliates?")

          click_on "Save changes"
          expect(page).to have_modal("Remove affiliates?")
          within_modal("Remove affiliates?") do
            click_on "Yes, continue"
          end

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path "/collaborators"
        end.to change { collaborator.products.count }.from(2).to(3)
           .and change { product1.reload.is_collab }.from(true).to(false)
           .and change { product4.direct_affiliates.count }.from(1).to(0)

        collaborator.reload
        expect(collaborator.affiliate_basis_points).to eq 30_00
        expect(collaborator.products).to match_array [product2, product3, product4]
        expect(collaborator.apply_to_all_products).to eq false
        product_2_collab = collaborator.product_affiliates.find_by(product: product2)
        expect(product_2_collab.dont_show_as_co_creator).to eq false
        expect(product_2_collab.affiliate_basis_points).to eq 25_00
        expect(collaborator.product_affiliates.find_by(product: product3).affiliate_basis_points).to eq 30_00
        expect(collaborator.product_affiliates.find_by(product: product4).affiliate_basis_points).to eq 45_00
      end
    end
  end
end
