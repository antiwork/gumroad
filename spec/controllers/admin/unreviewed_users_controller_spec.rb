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
      before do
        $redis.del(RedisKey.unreviewed_users_cutoff_date)
      end

      context "when no cached data exists" do
        before do
          $redis.del(RedisKey.unreviewed_users_data)
        end

        it "returns empty state with default cutoff_date" do
          get :index

          expect(response).to be_successful
          expect(inertia.component).to eq "Admin/UnreviewedUsers/Index"
          expect(inertia.props[:users]).to be_empty
          expect(inertia.props[:total_count]).to eq(0)
          expect(inertia.props[:cutoff_date]).to eq("2024-01-01")
        end
      end

      context "when cached data exists" do
        let!(:unreviewed_user) do
          create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        end

        before do
          create(:balance, user: unreviewed_user, amount_cents: 5000)
          Admin::UnreviewedUsersService.cache_users_data!
        end

        it "returns cached users with props from service" do
          get :index

          expect(response).to be_successful
          expect(inertia.props[:users].size).to eq(1)
          expect(inertia.props[:users].first[:external_id]).to eq(unreviewed_user.external_id)
          expect(inertia.props[:total_count]).to eq(1)
          expect(inertia.props[:cutoff_date]).to eq("2024-01-01")
        end
      end

      context "when user is reviewed after caching" do
        let!(:user) do
          create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
        end

        before do
          create(:balance, user:, amount_cents: 5000)
          Admin::UnreviewedUsersService.cache_users_data!
          user.update!(user_risk_state: "compliant")
        end

        it "filters out users who are no longer not_reviewed" do
          get :index

          expect(inertia.props[:users]).to be_empty
          # total_count still reflects cached total
          expect(inertia.props[:total_count]).to eq(1)
        end
      end
    end
  end
end
