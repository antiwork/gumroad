# frozen_string_literal: true

require "spec_helper"

describe "Collaborations", type: :system, js: true do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:seller_3) { create(:user) }

  let(:seller_1_product_1) { create(:product, user: seller_1, name: "First product") }
  let(:seller_1_product_2) { create(:product, user: seller_1, name: "Second product") }

  let(:seller_2_product_1) { create(:product, user: seller_2, name: "Third product") }
  let(:seller_2_product_2) { create(:product, user: seller_2, name: "Fourth product") }

  let(:seller_3_product_1) { create(:product, user: seller_3, name: "Fifth product") }

  let(:collaborator_1) do
    create(:collaborator, seller: seller_1, affiliate_user:).tap do |collaborator|
      collaborator.product_affiliates.create!(
        product: seller_1_product_1,
        affiliate_basis_points: 50_00
      )
      collaborator.product_affiliates.create!(
        product: seller_1_product_2,
        affiliate_basis_points: 35_00
      )
    end
  end
  let(:collaborator_2) do
    create(:collaborator, seller: seller_2, affiliate_user:).tap do |collaborator|
      collaborator.product_affiliates.create!(
        product: seller_2_product_1,
        affiliate_basis_points: 50_00
      )
      collaborator.product_affiliates.create!(
        product: seller_2_product_2,
        affiliate_basis_points: 35_00
      )
    end
  end
  let(:collaborator_3_pending) do
    create(
      :collaborator,
      :with_pending_invitation,
      seller: seller_3,
      affiliate_user:
    ).tap do |collaborator|
      collaborator.product_affiliates.create!(
        product: seller_3_product_1,
        affiliate_basis_points: 20_00
      )
    end
  end

  describe "seller view" do
    let(:affiliate_user) { create(:user) }

    before { login_as affiliate_user }

    context "viewing collaborations" do
      it "only shows the tabs when there are collaborations" do
        visit collaborators_path
        expect(page).to_not have_tab_button("Collaborators")
        expect(page).to_not have_tab_button("Collaborations")

        collaborator_1

        visit collaborators_path
        expect(page).to have_tab_button("Collaborators")
        expect(page).to have_tab_button("Collaborations")
      end

      it "displays a list of collaborators" do
        collaborator_1
        collaborator_2
        collaborator_3_pending

        visit collaborators_incomings_path

        [
          {
            "Name" => collaborator_1.seller.username,
            "Products" => "2 products",
            "Your cut" => "35% - 50%",
            "Status" => "Accepted"
          },
          {
            "Name" => collaborator_2.seller.username,
            "Products" => "2 products",
            "Your cut" => "35% - 50%",
            "Status" => "Accepted"
          },
          {
            "Name" => collaborator_3_pending.seller.username,
            "Products" => seller_3_product_1.name,
            "Your cut" => "20%",
            "Status" => "Pending"
          },
        ].each do |row|
          expect(page).to have_table_row(row)
        end
      end
    end

    context "invitations" do
      it "allows accepting an invitation" do
        collaborator_3_pending

        visit collaborators_incomings_path

        expect(page).to have_table_row(
          {
            "Name" => collaborator_3_pending.seller.username,
            "Status" => "Pending"
          }
        )

        within find(:table_row, { "Name" => collaborator_3_pending.seller.username }) do
          click_on "Accept"
        end

        expect(page).to have_alert(text: "Invitation accepted")
        expect(page).to have_table_row(
          {
            "Name" => collaborator_3_pending.seller.username,
            "Status" => "Accepted"
          }
        )
      end

      it "allows declining an invitation" do
        collaborator_3_pending

        visit collaborators_incomings_path

        expect(page).to have_table_row(
          {
            "Name" => collaborator_3_pending.seller.username,
            "Status" => "Pending"
          }
        )

        within find(:table_row, { "Name" => collaborator_3_pending.seller.username }) do
          click_on "Decline"
        end

        expect(page).to have_alert(text: "Invitation declined")
        expect(page).to_not have_table_row({ "Name" => collaborator_3_pending.seller.username })
        expect(page).to have_text("No collaborations yet")
      end
    end

    context "removing a collaborator" do
      it "allows removing a collaborator" do
        collaborator_1

        visit collaborators_incomings_path

        expect(page).to have_table_row(
          {
            "Name" => collaborator_1.seller.username,
            "Status" => "Accepted"
          }
        )

        find(:table_row, { "Name" => collaborator_1.seller.username }).click
        within_section collaborator_1.seller.username, section_element: :aside do
          click_on "Remove"
        end

        expect(page).to have_alert(text: "Collaborator removed")
        expect(page).to_not have_table_row({ "Name" => collaborator_1.seller.username })
        expect(page).to have_text("No collaborations yet")
      end
    end
  end
end
