# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::UnreviewedUsersController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin) { create(:admin_user) }

  before do
    sign_in admin
  end

  describe "GET #index" do
    context "when not logged in" do
      before { sign_out admin }

      it "redirects to login" do
        get :index

        expect(response).to redirect_to(login_path(next: admin_unreviewed_users_path))
      end
    end

    context "when logged in as non-admin" do
      let(:regular_user) { create(:user) }

      before do
        sign_out admin
        sign_in regular_user
      end

      it "redirects to root" do
        get :index

        expect(response).to redirect_to(root_path)
      end
    end

    context "when logged in as admin" do
      it "returns successful response" do
        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq "Admin/UnreviewedUsers/Index"
      end

      it "returns empty list when no unreviewed users exist" do
        get :index

        expect(response).to be_successful
        expect(inertia.props[:users]).to be_empty
        expect(inertia.props[:total_count]).to eq(0)
      end

      context "with unreviewed users with unpaid balance" do
        let!(:unreviewed_user_with_balance) do
          user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 5000)
          user
        end

        let!(:unreviewed_user_with_low_balance) do
          user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 500)
          user
        end

        let!(:compliant_user_with_balance) do
          user = create(:user, user_risk_state: "compliant", created_at: 1.year.ago)
          create(:balance, user:, amount_cents: 5000)
          user
        end

        let!(:old_unreviewed_user) do
          user = create(:user, user_risk_state: "not_reviewed", created_at: 3.years.ago)
          create(:balance, user:, amount_cents: 5000)
          user
        end

        it "returns only unreviewed users with balance > $10 created within 2 years" do
          get :index

          user_ids = inertia.props[:users].map { |u| u[:id] }

          expect(user_ids).to include(unreviewed_user_with_balance.id)
          expect(user_ids).not_to include(unreviewed_user_with_low_balance.id)
          expect(user_ids).not_to include(compliant_user_with_balance.id)
          expect(user_ids).not_to include(old_unreviewed_user.id)
        end

        it "returns total count" do
          get :index

          expect(inertia.props[:total_count]).to eq(1)
        end

        it "returns user details" do
          get :index

          user_data = inertia.props[:users].find { |u| u[:id] == unreviewed_user_with_balance.id }

          expect(user_data[:id]).to eq(unreviewed_user_with_balance.id)
          expect(user_data[:email]).to eq(unreviewed_user_with_balance.email)
          expect(user_data[:unpaid_balance_cents]).to eq(5000)
          expect(user_data[:admin_url]).to eq(admin_user_path(unreviewed_user_with_balance.external_id))
        end

        it "orders users by unpaid balance descending" do
          user_with_higher_balance = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
          create(:balance, user: user_with_higher_balance, amount_cents: 10000)

          get :index

          user_ids = inertia.props[:users].map { |u| u[:id] }

          expect(user_ids.first).to eq(user_with_higher_balance.id)
        end

        it "includes old users when cutoff_date param is provided" do
          get :index, params: { cutoff_date: 4.years.ago.to_date.to_s }

          user_ids = inertia.props[:users].map { |u| u[:id] }

          expect(user_ids).to include(old_unreviewed_user.id)
        end

        it "returns cutoff_date in response" do
          get :index

          expect(inertia.props[:cutoff_date]).to eq(2.years.ago.to_date.to_s)
        end
      end

      context "with revenue source badges" do
        let(:user) { create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago) }
        let!(:balance) { create(:balance, user:, amount_cents: 5000) }

        it "includes sales badge when user has sales balance" do
          product = create(:product, user:)
          create(:purchase, seller: user, link: product, purchase_success_balance: balance)

          get :index

          user_data = inertia.props[:users].find { |u| u[:id] == user.id }

          expect(user_data[:revenue_sources]).to include("sales")
        end

        it "includes affiliate badge when user has affiliate credits" do
          product = create(:product)
          direct_affiliate = create(:direct_affiliate, affiliate_user: user, seller: product.user, products: [product])
          purchase = create(:purchase, link: product, affiliate: direct_affiliate)
          create(:affiliate_credit, affiliate_user: user, seller: product.user, purchase:, link: product, affiliate: direct_affiliate, affiliate_credit_success_balance: balance)

          get :index

          user_data = inertia.props[:users].find { |u| u[:id] == user.id }

          expect(user_data[:revenue_sources]).to include("affiliate")
        end

        it "includes collaborator badge when user has collaborator credits" do
          seller = create(:user)
          product = create(:product, user: seller)
          collaborator = create(:collaborator, affiliate_user: user, seller: seller, products: [product])
          purchase = create(:purchase, link: product, affiliate: collaborator)
          create(:affiliate_credit, affiliate_user: user, seller: seller, purchase:, link: product, affiliate: collaborator, affiliate_credit_success_balance: balance)

          get :index

          user_data = inertia.props[:users].find { |u| u[:id] == user.id }

          expect(user_data[:revenue_sources]).to include("collaborator")
          expect(user_data[:revenue_sources]).not_to include("affiliate")
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

        it "returns first page of users" do
          get :index

          expect(inertia.props[:users].length).to eq(2)
          expect(inertia.props[:pagination][:page]).to eq(1)
        end

        it "returns second page when requested" do
          get :index, params: { page: 2 }

          expect(inertia.props[:users].length).to eq(1)
          expect(inertia.props[:pagination][:page]).to eq(2)
        end
      end
    end
  end
end
