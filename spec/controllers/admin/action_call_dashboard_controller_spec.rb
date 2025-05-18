# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::ActionCallDashboardController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET #index" do
    it "assigns all admin_action_call_infos as @admin_action_call_infos ordered by call_count descending" do
      admin_action_call_info1 = create(:admin_action_call_info, call_count: 3)
      admin_action_call_info2 = create(:admin_action_call_info, action_name: "stats", call_count: 5)

      get :index

      expect(assigns(:admin_action_call_infos)).to eq([admin_action_call_info2, admin_action_call_info1])
    end

    it "renders the index template" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(response).to render_template(:index)
    end
  end
end
