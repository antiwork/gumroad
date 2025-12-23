# frozen_string_literal: true

require "spec_helper"

describe "Admin::UnreviewedUsersController", type: :system, js: true do
  let(:admin) { create(:admin_user) }

  before do
    login_as(admin)
  end

  describe "GET /admin/unreviewed_users" do
    it "displays the unreviewed users page" do
      visit admin_unreviewed_users_path

      expect(page).to have_text("Unreviewed users")
    end

    context "when there are no unreviewed users" do
      it "shows empty state message" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("No unreviewed users with unpaid balance found")
      end
    end

    context "when there are unreviewed users with unpaid balance" do
      let!(:user_with_balance) do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago, name: "Test Creator")
        create(:balance, user:, amount_cents: 5000)
        user
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

      it "shows the cutoff date in the summary" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("created since #{2.years.ago.to_date}")
      end
    end

    context "with revenue source badges" do
      let(:user) { create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago) }
      let!(:balance) { create(:balance, user:, amount_cents: 5000) }

      it "shows sales badge when user has sales" do
        product = create(:product, user:)
        create(:purchase, seller: user, link: product, purchase_success_balance: balance)

        visit admin_unreviewed_users_path

        expect(page).to have_text("sales")
      end

      it "shows affiliate badge when user has affiliate credits" do
        product = create(:product)
        direct_affiliate = create(:direct_affiliate, affiliate_user: user, seller: product.user, products: [product])
        purchase = create(:purchase, link: product, affiliate: direct_affiliate)
        create(:affiliate_credit, affiliate_user: user, seller: product.user, purchase:, link: product, affiliate: direct_affiliate, affiliate_credit_success_balance: balance)

        visit admin_unreviewed_users_path

        expect(page).to have_text("affiliate")
      end

      it "shows collaborator badge when user has collaborator credits" do
        seller = create(:user)
        product = create(:product, user: seller)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller, products: [product])
        purchase = create(:purchase, link: product, affiliate: collaborator)
        create(:affiliate_credit, affiliate_user: user, seller: seller, purchase:, link: product, affiliate: collaborator, affiliate_credit_success_balance: balance)

        visit admin_unreviewed_users_path

        expect(page).to have_text("collaborator")
      end
    end

    context "with pagination" do
      before do
        stub_const("Admin::UnreviewedUsersController::RECORDS_PER_PAGE", 2)
        3.times do |i|
          user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 2000 + (i * 100))
        end
      end

      it "shows count of total users" do
        visit admin_unreviewed_users_path

        expect(page).to have_text("of 3 unreviewed users")
      end
    end

    context "with cutoff_date parameter" do
      let!(:old_user) do
        user = create(:user, user_risk_state: "not_reviewed", created_at: 3.years.ago)
        create(:balance, user:, amount_cents: 5000)
        user
      end

      it "excludes old users by default" do
        visit admin_unreviewed_users_path

        expect(page).not_to have_text(old_user.email)
      end

      it "includes old users when cutoff_date param is provided" do
        visit admin_unreviewed_users_path(cutoff_date: 4.years.ago.to_date.to_s)

        expect(page).to have_text(old_user.email)
      end
    end
  end
end
