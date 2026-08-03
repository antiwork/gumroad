# frozen_string_literal: true

require "spec_helper"

describe UtmLinkTrackingController do
  let(:seller) { create(:user) }
  let(:utm_link) { create(:utm_link, seller:) }

  describe "GET show" do
    it "redirects to the utm_link's url" do
      get :show, params: { permalink: utm_link.permalink }

      expect(response).to redirect_to(utm_link.utm_url)
    end

    it "returns a not found response instead of raising when the target resource is gone" do
      product = create(:product, user: seller)
      link_to_dangling_product = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)
      product.delete

      expect { get :show, params: { permalink: link_to_dangling_product.permalink } }.not_to raise_error
      expect(response).to have_http_status(:not_found)
    end
  end
end
