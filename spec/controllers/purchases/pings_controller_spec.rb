# frozen_string_literal: false

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe Purchases::PingsController do
  it_behaves_like "inherits from Sellers::BaseController"

  render_views

  describe "POST create" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    context "when making a request while unauthenticated" do
      it "does not allow resending the ping" do
        expect_any_instance_of(Purchase).to_not receive(:send_notification_webhook_from_ui)

        post :create, format: :json, params: { purchase_id: purchase.external_id }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when making a request while authenticated" do
      context "when signed in as a user other than the seller of the purchase for which a ping is to be resent" do
        it "does not allow resending the ping" do
          expect_any_instance_of(Purchase).to_not receive(:send_notification_webhook_from_ui)

          sign_in(create(:user))
          post :create, format: :json, params: { purchase_id: purchase.external_id }

          expect(response).to have_http_status(:not_found)
        end
      end

      context "when signed in as the seller of the purchase for which a ping is to be resent" do
        include_context "with user signed in as admin for seller"

        it_behaves_like "authorize called for action", :post, :create do
          let(:record) { purchase }
          let(:policy_klass) { Audience::PurchasePolicy }
          let(:policy_method) { :create_ping? }
          let(:request_params) { { purchase_id: purchase.external_id } }
        end

        it "resends the ping and responds with success" do
          expect_any_instance_of(Purchase).to(
            receive(:send_notification_webhook_from_ui).and_call_original)

          post :create, format: :json, params: { purchase_id: purchase.external_id }

          expect(response).to be_successful
        end
      end
    end
  end
end
