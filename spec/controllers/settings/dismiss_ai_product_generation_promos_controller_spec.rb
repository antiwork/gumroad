# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::DismissAiProductGenerationPromosController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { seller }
      let(:policy_method) { :generate_product_details_with_ai? }
    end

    context "when user is authenticated and authorized" do
      before do
        Feature.activate(:ai_product_generation)
        seller.confirm
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(15_000)
        create(:payment_completed, user: seller)
      end

      it "dismisses the AI product generation promo alert" do
        expect(seller.dismissed_create_products_with_ai_promo_alert).to be(false)

        post :create

        expect(response).to have_http_status(:ok)
        expect(seller.reload.dismissed_create_products_with_ai_promo_alert).to be(true)
      end

      it "works when promo alert is already dismissed" do
        seller.update!(dismissed_create_products_with_ai_promo_alert: true)

        post :create

        expect(response).to have_http_status(:ok)
        expect(seller.reload.dismissed_create_products_with_ai_promo_alert).to be(true)
      end
    end
  end
end
