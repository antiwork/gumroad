# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::PayoutsController do
  it_behaves_like "inherits from Admin::BaseController"

  describe "GET 'show'" do
    it "shows a payout" do
      admin_user = create(:admin_user)
      payment = create(:payment_completed)

      sign_in admin_user
      get :show, params: { id: payment.id }

      expect(response).to be_successful
      expect(assigns(:payment)).to eq(payment)
      expect(assigns(:title)).to eq("Payout")
    end
  end
end

