# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::PayoutsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:payout_period_end_date) { Date.today - 1 }

  before do
    @admin_user = create(:admin_user)
    @admin_user_with_payout_privileges = create(:admin_user, has_payout_privilege: true)
    @params = {
      payout_period_end_date: payout_period_end_date.to_s,
      passphrase: "1234"
    }
  end

  describe "GET 'index'" do
    render_views

    before do
      @admin_user = create(:admin_user)
      @user = create(:user)
      @payout_1 = create(:payment_completed, user: @user)
      @payout_2 = create(:payment_failed, user: @user)
      @other_user_payout = create(:payment_failed)
    end

    it "lists all the payouts for a user" do
      sign_in @admin_user
      get :index, params: { user_id: @user.id }

      payouts = assigns(:payouts)
      expect(payouts.count).to eq(@user.payments.count)
      expect(payouts.exclude?(@other_user_payout)).to be(true)
      expect(payouts.first).to eq(@payout_2)

      expect(response.body).to include("Payouts")
      expect(response.body).to include(admin_payout_path(@payout_1))
    end
  end
end
