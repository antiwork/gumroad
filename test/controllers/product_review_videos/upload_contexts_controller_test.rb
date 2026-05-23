# frozen_string_literal: true

require "test_helper"
require "shared_examples/authentication_required"

class ProductReviewVideosUploadContextsControllerTest < ActionController::TestCase
  self.described_class = ProductReviewVideos::UploadContextsController
  tests ProductReviewVideos::UploadContextsController



  context_ ProductReviewVideos::UploadContextsController do
  context_ "GET show" do
      let(:user) { create(:user) }

      it_behaves_like "authentication required for action", :get, :show

  context_ "when user is authenticated" do
        before { sign_in user }

  test "returns the upload context with correct values" do
          get :show

          expect(response).to be_successful
          expect(response.parsed_body).to match(
            aws_access_key_id: AWS_ACCESS_KEY,
            s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
            user_id: user.external_id
          )
        end
      end
    end
  end
end
