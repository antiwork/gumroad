# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::Installments::PreviewEmailsController do
  let(:seller) { create(:user) }
  let(:installment) { create(:installment, seller:) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { installment }
      let(:policy_method) { :preview? }
      let(:request_params) { { id: record.external_id } }
    end

    it "sends a preview email" do
      allow(PostSendgridApi).to receive(:process).and_call_original

      post :create, params: { id: installment.external_id }, as: :json

      expect(response).to be_successful
      expect(PostSendgridApi).to have_received(:process).with(
        post: installment,
        recipients: [{ email: seller.seller_memberships.role_admin.sole.user.email }],
        preview: true,
      )
    end

    it "sends a preview email to the impersonated Gumroad admin" do
      gumroad_admin = create(:admin_user)
      sign_in(gumroad_admin)
      controller.impersonate_user(seller)
      expect_any_instance_of(Installment).to receive(:send_preview_email).with(gumroad_admin)

      post :create, params: { id: installment.external_id }, as: :json
    end

    it "returns an error while previewing an email if the logged-in user has uncofirmed email" do
      controller.logged_in_user.update_attribute(:unconfirmed_email, "john@example.com")
      expect(PostSendgridApi).to_not receive(:process)

      post :create, params: { id: installment.external_id }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "You have to confirm your email address before you can do that.")
    end
  end
end
