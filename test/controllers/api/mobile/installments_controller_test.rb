# frozen_string_literal: true

require "test_helper"

class ApiMobileInstallmentsControllerTest < ActionController::TestCase
  self.described_class = Api::Mobile::InstallmentsController
  tests Api::Mobile::InstallmentsController



  context_ Api::Mobile::InstallmentsController do
    before do
      @product = create(:subscription_product, user: create(:user))
      @post = create(:installment, link: @product, published_at: Time.current)
      @follower = create(:follower)
    end

  test "returns an error response for a unknown installment" do
      get :show, params: { id: "xxx", mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }

      assert_response :not_found
      expect(response.parsed_body).to eq({
        success: false,
        message: "Could not find installment"
      }.as_json)
    end

  test "returns the correct information if installment is available" do
      get :show, params: { id: @post.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, follower_id: @follower.external_id }

      assert_response :success
      expect(response.parsed_body).to eq({ success: true, installment: @post.installment_mobile_json_data(follower: @follower) }.as_json)
    end

  test "returns error if none of purchase, subscription, or followers is provided" do
      get :show, params: { id: @post.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }

      assert_response :not_found
      expect(response.parsed_body).to eq({
        success: false,
        message: "Could not find related object to the installment."
      }.as_json)
    end
  end
end
