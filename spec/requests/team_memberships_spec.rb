# frozen_string_literal: true

require "spec_helper"

describe "Team Memberships", type: :system, js: true do
  describe "Account switch" do
    context "with logged in user" do
      let(:user) { create(:user, name: "Gum") }

      before do
        create(:user_compliance_info, user:)
        login_as user
      end

      context "with one team memberships" do
        let(:seller) { create(:user, name: "Joe") }

        before do
          create(:user_compliance_info, user: seller, first_name: "Joey")
          create(:team_membership, user:, seller:)
        end

        it "switches account to seller" do
          visit products_path

          within "nav[aria-label='Main']" do
            toggle_disclosure("Gum")
            choose("Joe")
            wait_for_ajax
            expect(page).to have_text(seller.display_name)
          end
          expect(page).to have_text("Products")
        end

        it "hides a deleted brand and lists it again after restoration" do
          brand = create(:user, name: "Synthetic brand")
          membership = create(:team_membership, user:, seller: brand)
          brand.deactivate!

          visit products_path

          within "nav[aria-label='Main']" do
            toggle_disclosure("Gum")
            expect(page).to have_selector("[role='menuitemradio']", text: "Gum")
            expect(page).to have_selector("[role='menuitemradio']", text: "Joe")
            expect(page).not_to have_selector("[role='menuitemradio']", text: "Synthetic brand")
          end
          expect(membership.reload).not_to be_deleted

          brand.reactivate!
          page.refresh

          within "nav[aria-label='Main']" do
            toggle_disclosure("Gum")
            expect(page).to have_selector("[role='menuitemradio']", text: "Synthetic brand")
          end
        end

        context "accessing a restricted page" do
          it "redirects to the dashboard" do
            visit settings_password_path

            within "nav[aria-label='Main']" do
              toggle_disclosure("Gum")
              choose("Joe")
              wait_for_ajax
              expect(page).to have_text(seller.display_name)
            end

            expect(page).not_to have_alert(text: "Your current role as Admin cannot perform this action.")
            expect(page.current_path).to eq(dashboard_path)
          end
        end
      end
    end
  end
end
