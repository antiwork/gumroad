# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"

class AdminUsersLatestPostsControllerTest < ActionController::TestCase
  self.described_class = Admin::Users::LatestPostsController
  tests Admin::Users::LatestPostsController



  context_ Admin::Users::LatestPostsController do
    it_behaves_like "inherits from Admin::BaseController"

    let(:admin_user) { create(:admin_user) }
    let(:user) { create(:user) }

    before do
      sign_in admin_user
    end

  context_ "GET 'index'" do
  context_ "when user has posts" do
        let!(:posts) { create_list(:post, 6, seller: user) }

  test "returns the user's last 5 created posts as JSON" do
          get :index, params: { user_external_id: user.external_id }, format: :json

          expect(response).to have_http_status(:success)
          expect(response.parsed_body.length).to eq(5)
        end
      end

  context_ "when user has no posts" do
  test "returns an empty array" do
          get :index, params: { user_external_id: user.external_id }, format: :json

          expect(response).to have_http_status(:success)
          expect(response.parsed_body).to eq([])
        end
      end
    end
  end
end
