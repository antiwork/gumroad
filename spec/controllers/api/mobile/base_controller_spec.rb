# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::BaseController do
  let(:application) { create(:oauth_application) }
  let(:admin_user) { create(:admin_user) }
  let(:access_token) do
    create(
      "doorkeeper/access_token",
      application:,
      resource_owner_id: admin_user.id,
      scopes: "creator_api"
    ).token
  end
  let(:params) do
    {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token:
    }
  end

  controller(Api::Mobile::BaseController) do
    def index
      head :ok
    end
  end

  it "uses the API user as the current resource owner" do
    get(:index, params:)

    expect(controller.current_resource_owner).to eq(admin_user)
  end
end
