# frozen_string_literal: true

require "spec_helper"

describe "Main Navigation", type: :system, js: true do
  context "with logged in user" do
    let(:user) { create(:user, name: "Gum") }

    before do
      login_as user
    end

    it "renders all menu links" do
      visit library_path

      within "nav[aria-label='Main']" do
        expect(page).to have_link("Workflows")
        expect(page).to have_link("Sales")
        expect(page).to have_link("Products")
        expect(page).to have_link("Emails")
        expect(page).to have_link("Analytics")

        expect(page).to have_link("Payouts")
        expect(page).to have_link("Discover")
        expect(page).to have_link("Library")

        expect(page).to have_link("Settings")

        expect(page).to have_link("Collaborators")

        expect(page).not_to have_link("Community")

        toggle_disclosure("Gum")
        within "div[role='menu']" do
          expect(page).to_not have_text(user.display_name)
          expect(page).to have_menuitem("Profile")
          expect(page).to have_menuitem("Affiliates")
          expect(page).to have_menuitem("Logout")
        end
      end
    end

    context "Community link" do
      it "renders the Community link if the logged in seller has an active community" do
        Feature.activate_user(:communities, user)

        product = create(:product, user:, community_chat_enabled: true)
        create(:community, seller: user, resource: product)

        visit library_path

        within "nav[aria-label='Main']" do
          expect(page).to have_link("Community", href: community_path)
        end
      end

      it "renders the Community link if the logged in user has an access to a community" do
        seller = create(:user)
        Feature.activate_user(:communities, seller)

        product = create(:product, user: seller, community_chat_enabled: true)
        create(:community, resource: product, seller:)
        create(:purchase, seller:, link: product, purchaser: user)

        visit library_path

        within "nav[aria-label='Main']" do
          expect(page).to have_link("Community", href: community_path)
        end
      end

      it "renders the Community link if the logged in user is a seller but has no active communities" do
        Feature.activate_user(:communities, user)
        create(:product, user:)

        visit library_path

        within "nav[aria-label='Main']" do
          expect(page).not_to have_link("Community", href: community_path)
        end
      end
    end

    context "with team membership" do
      let(:seller) { create(:user, name: "Joe") }

      before do
        create(:team_membership, user:, seller:)
      end

      it "renders memberships" do
        visit library_path

        within "nav[aria-label='Main']" do
          toggle_disclosure("Gum")
          within "div[role='menu']" do
            expect(page).to have_text(user.display_name)
            expect(page).to have_text(seller.display_name)
          end
        end
      end
    end
  end
end
