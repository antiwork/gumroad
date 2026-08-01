# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ShipmentsController, :vcr do
  describe "POST mark_as_shipped" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }
    let(:purchase_with_shipment) { create(:purchase, link: product, seller:) }
    let!(:shipment) { create(:shipment, purchase: purchase_with_shipment) }
    let(:tracking_url) { "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890" }

    include_context "with user signed in as admin for seller"

    it_behaves_like "authorize called for action", :post, :mark_as_shipped do
      let(:record) { purchase }
      let(:policy_klass) { Audience::PurchasePolicy }
      let(:request_params) { { purchase_id: purchase.external_id } }
    end

    it "no shipment exists - should mark a purchase as shipped" do
      expect { post :mark_as_shipped, params: { purchase_id: purchase.external_id } }.to change { Shipment.count }.by(1)

      expect(response).to be_successful
      expect(purchase.shipment.shipped?).to be(true)
    end

    it "shipment exists - should mark a purchase as shipped" do
      expect { post :mark_as_shipped, params: { purchase_id: purchase_with_shipment.external_id } }.to change { Shipment.count }.by(0)

      expect(response).to be_successful
      expect(shipment.reload.shipped?).to be(true)
    end

    describe "tracking information" do
      it "no shipment exists - should mark a purchase as shipped" do
        expect { post :mark_as_shipped, params: { purchase_id: purchase.external_id, tracking_url: } }.to change { Shipment.count }.by(1)

        expect(response).to be_successful
        expect(purchase.shipment.shipped?).to be(true)
        expect(purchase.shipment.tracking_url).to eq(tracking_url)
      end

      it "shipment exists - should mark a purchase as shipped" do
        expect { post :mark_as_shipped, params: { purchase_id: purchase_with_shipment.external_id, tracking_url: } }.to change { Shipment.count }.by(0)

        expect(response).to be_successful
        expect(shipment.reload.shipped?).to be(true)
        expect(shipment.tracking_url).to eq(tracking_url)
      end

      it "rejects tracking values that are not full URLs" do
        expect { post :mark_as_shipped, params: { purchase_id: purchase.external_id, tracking_url: "1Z999AA10123456784" } }.not_to change { Shipment.count }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to eq("Tracking URL #{Shipment::VALID_TRACKING_LINK_MESSAGE}")
        expect(purchase.reload.shipment).to eq(nil)
      end
    end
  end
end
