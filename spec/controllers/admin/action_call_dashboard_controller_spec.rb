# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"
require "shared_examples/admin_base_controller_concern"

describe Admin::ActionCallDashboardController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET #index" do
    it "renders the inertia page with admin_action_call_infos ordered by call_count descending" do
      admin_action_call_info1 = create(:admin_action_call_info, call_count: 3)
      admin_action_call_info2 = create(:admin_action_call_info, action_name: "stats", call_count: 5)

      get :index

      expect(response).to have_http_status(:ok)
      expect_inertia.to render_component "Admin/ActionCallDashboard/Index"
      expect(inertia.props[:admin_action_call_infos]).to eq([admin_action_call_info2, admin_action_call_info1].map do |info|
        {
          id: info.id,
          controller_name: info.controller_name,
          action_name: info.action_name,
          call_count: info.call_count
        }
      end)
    end
  end
end
