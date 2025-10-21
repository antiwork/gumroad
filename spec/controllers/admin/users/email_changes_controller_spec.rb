# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::EmailChangesController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user, email: "oldemail@example.com", payment_address: "old_address@example.com") }

  before do
    sign_in admin_user
  end

  describe "GET 'index'" do
    context "when user has email and payment_address changes", versioning: true do
      before do
        user.update!(payment_address: "new_address@example.com")
        user.update!(email: "newemail@example.com")
        user.confirm
      end

      it "returns email changes and fields" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)

        expect(response.parsed_body).to match(
          "email_changes" => [
            {
              "created_at" => an_instance_of(String),
              "changes" => { "email" => ["oldemail@example.com", "newemail@example.com"] }
            },
            {
              "created_at" => an_instance_of(String),
              "changes" => { "payment_address" => ["old_address@example.com", "new_address@example.com"] }
            },
            {
              "created_at" => an_instance_of(String),
              "changes" => { "email" => ["", "oldemail@example.com"], "payment_address" => [nil, "old_address@example.com"] }
            }
          ],
          "fields" => ["email", "payment_address"]
        )
      end
    end

    context "when user has no changes" do
      it "returns empty email changes" do
        get :index, params: { user_id: user.id }, format: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to eq(
          "email_changes" => [],
          "fields" => ["email", "payment_address"]
        )
      end
    end
  end
end
