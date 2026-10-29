# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::WaitlistEmailsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Installment }
      let(:policy_method) { :create? }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    it "starts the waitlist email and returns where to edit it" do
      expect do
        post :create, params: { product_id: product.unique_permalink }, as: :json
      end.to change { seller.installments.count }.by(1)

      email = seller.installments.last
      expect(response.parsed_body).to eq("success" => true, "edit_url" => "/emails/#{email.external_id}/edit")
      expect(email.waitlisted_products).to eq([product.unique_permalink])
    end

    it "refuses a seller who cannot send emails yet" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(0)

      expect do
        post :create, params: { product_id: product.unique_permalink }, as: :json
      end.not_to change { Installment.count }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "reports the sending limit instead of failing" do
      allow_any_instance_of(Installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(0)

      post :create, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to start_with("Sorry, you cannot send out more than #{Installment::SENDING_LIMIT} emails")
    end

    it "404s for another seller's product" do
      expect do
        post :create, params: { product_id: create(:product).unique_permalink }, as: :json
      end.to raise_error(ActionController::RoutingError)
    end
  end
end
