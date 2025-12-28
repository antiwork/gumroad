# frozen_string_literal: true

require "spec_helper"

describe "Admin::UnreviewedUsersController", type: :system, js: true do
  let(:admin) { create(:admin_user) }

  before do
    login_as(admin)
  end

  describe "GET /admin/unreviewed_users" do
    context "when no cached data exists" do
      before do
        $redis.del(RedisKey.unreviewed_users_data)
      end

      it "shows empty state message" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("No unreviewed users with unpaid balance found")
      end
    end

    context "when cached data exists" do
      let!(:user_with_balance) do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago, name: "Test Creator")
        create(:balance, user:, amount_cents: 5000)
        user
      end

      before do
        Admin::UnreviewedUsersService.cache_users_data!
      end

      it "displays the unreviewed users page" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("Unreviewed users")
      end

      it "displays user information" do
        visit admin_unreviewed_users_path

        expect(page).to have_text(user_with_balance.external_id)
        expect(page).to have_text(user_with_balance.email)
        expect(page).to have_text("$50")
      end

      it "links to the user's admin page" do
        visit admin_unreviewed_users_path

        expect(page).to have_link(user_with_balance.external_id, href: admin_user_path(user_with_balance.external_id))
      end

      it "shows the cutoff date in the header" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("created since 2024-01-01")
      end
    end

    context "with revenue source badges" do
      let(:user) { create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago) }
      let!(:balance) { create(:balance, user:, amount_cents: 5000) }

      it "shows sales badge when user has sales" do
        product = create(:product, user:)
        create(:purchase, seller: user, link: product, purchase_success_balance: balance)
        Admin::UnreviewedUsersService.cache_users_data!

        visit admin_unreviewed_users_path

        expect(page).to have_text("sales")
      end

      it "shows affiliate badge when user has affiliate credits" do
        product = create(:product)
        direct_affiliate = create(:direct_affiliate, affiliate_user: user, seller: product.user, products: [product])
        purchase = create(:purchase, link: product, affiliate: direct_affiliate)
        create(:affiliate_credit, affiliate_user: user, seller: product.user, purchase:, link: product, affiliate: direct_affiliate, affiliate_credit_success_balance: balance)
        Admin::UnreviewedUsersService.cache_users_data!

        visit admin_unreviewed_users_path

        expect(page).to have_text("affiliate")
      end

      it "shows collaborator badge when user has collaborator credits" do
        seller = create(:user)
        product = create(:product, user: seller)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller, products: [product])
        purchase = create(:purchase, link: product, affiliate: collaborator)
        create(:affiliate_credit, affiliate_user: user, seller: seller, purchase:, link: product, affiliate: collaborator, affiliate_credit_success_balance: balance)
        Admin::UnreviewedUsersService.cache_users_data!

        visit admin_unreviewed_users_path

        expect(page).to have_text("collaborator")
      end
    end

    context "filters out reviewed users" do
      let!(:user) do
        create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
      end

      before do
        create(:balance, user:, amount_cents: 5000)
        Admin::UnreviewedUsersService.cache_users_data!
        user.update!(user_risk_state: "compliant")
      end

      it "does not show users who were reviewed after caching" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("No unreviewed users with unpaid balance found")
      end
    end
  end
end
