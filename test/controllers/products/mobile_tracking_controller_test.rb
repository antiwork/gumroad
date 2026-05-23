# frozen_string_literal: true

require "test_helper"

class ProductsMobileTrackingControllerTest < ActionController::TestCase
  self.described_class = Products::MobileTrackingController
  tests Products::MobileTrackingController



  context_ Products::MobileTrackingController do
  context_ "GET show" do
      let(:product) { create(:product) }

  test "assigns props for tracking" do
        expect(MobileTrackingPresenter).to receive(:new).with(seller: product.user).and_call_original

        get :show, params: { link_id: product.unique_permalink }

        expect(response).to have_http_status(:ok)
        expect(response).to render_template(:show)
        expect(assigns[:tracking_props][:permalink]).to eq(product.unique_permalink)
      end
    end
  end
end
