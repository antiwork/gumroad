# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::LatestPostsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user) }

  before do
    sign_in admin_user
  end

  describe "GET 'index'" do
    context "when user has posts" do
      let!(:posts) { create_list(:post, 6, seller: user) }

      it "returns the user's last 5 created posts as JSON" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.length).to eq(5)
      end
    end

    context "when user has no posts" do
      it "returns an empty array" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to eq([])
      end
    end
  end
end
