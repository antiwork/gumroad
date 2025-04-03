# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe EmailsController do
  it_behaves_like "inherits from Sellers::BaseController"

  render_views

  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Installment }
    end

    it "redirects to the published tab" do
      get :index

      expect(response).to redirect_to("/emails/published")
    end

    it "redirects to the scheduled tab if there are scheduled installments" do
      create(:installment, seller:, ready_to_publish: true)

      get :index

      expect(response).to redirect_to("/emails/scheduled")
    end
  end
end
