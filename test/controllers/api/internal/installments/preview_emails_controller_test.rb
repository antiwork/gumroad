# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

class ApiInternalInstallmentsPreviewEmailsControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::Installments::PreviewEmailsController
  tests Api::Internal::Installments::PreviewEmailsController



  context_ Api::Internal::Installments::PreviewEmailsController do
    let(:seller) { create(:user) }
    let(:installment) { create(:installment, seller:) }

    include_context "with user signed in as admin for seller"

  context_ "POST create" do
      it_behaves_like "authentication required for action", :post, :create do
        let(:request_params) { { id: installment.external_id } }
      end

      it_behaves_like "authorize called for action", :post, :create do
        let(:record) { installment }
        let(:policy_method) { :preview? }
        let(:request_params) { { id: record.external_id } }
      end

  test "sends a preview email" do
        allow(PostSendgridApi).to receive(:process).and_call_original

        post :create, params: { id: installment.external_id }, as: :json

        expect(response).to be_successful
        expect(PostSendgridApi).to have_received(:process).with(
          post: installment,
          recipients: [{ email: seller.seller_memberships.role_admin.sole.user.email }],
          preview: true,
        )
      end

  test "sends a preview email to the impersonated Gumroad admin" do
        gumroad_admin = create(:admin_user)
        sign_in(gumroad_admin)
        controller.impersonate_user(seller)
        expect_any_instance_of(Installment).to receive(:send_preview_email).with(gumroad_admin)

        post :create, params: { id: installment.external_id }, as: :json
      end

  test "returns an error when the email service raises ResendApiResponseError" do
        allow(PostEmailApi).to receive(:process).and_raise(ResendApiResponseError, "Application not found")

        post :create, params: { id: installment.external_id }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("message" => "Failed to send preview email. Please try again later.")
      end

  test "returns an error while previewing an email if the logged-in user has uncofirmed email" do
        controller.logged_in_user.update_attribute(:unconfirmed_email, "john@example.com")
        expect(PostSendgridApi).not_to receive(:process)

        post :create, params: { id: installment.external_id }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("message" => "You have to confirm your email address before you can do that.")
      end
    end
  end
end
