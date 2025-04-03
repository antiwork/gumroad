# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ShipmentsController, :vcr  do
  describe "POST verify_shipping_address" do
    describe "US address" do
      before do
        @params = {
          street_address: "1640 17th St",
          city: "San Francisco",
          state: "CA",
          zip_code: "94107",
          country: "United States"
        }
      end

      describe "valid address" do
        it "calls EasyPost" do
          expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_call_original
          post :verify_shipping_address, params: @params
        end

        it "returns correct response" do
          post :verify_shipping_address, params: @params
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["street_address"]).to eq "1640 17TH ST"
          expect(response.parsed_body["city"]).to eq "SAN FRANCISCO"
          expect(response.parsed_body["state"]).to eq "CA"
          expect(response.parsed_body["zip_code"]).to eq "94107"
        end

        describe "valid address but with minor corrections" do
          before do
            @params.merge!(street_address: "1640 17 Street")
          end

          it "calls EasyPost" do
            expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_call_original
            post :verify_shipping_address, params: @params
          end

          it "returns correct response" do
            post :verify_shipping_address, params: @params
            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["easypost_verification_required"]).to be(true)
            expect(response.parsed_body["street_address"]).to eq "1640 17TH ST"
            expect(response.parsed_body["city"]).to eq "SAN FRANCISCO"
            expect(response.parsed_body["state"]).to eq "CA"
            expect(response.parsed_body["zip_code"]).to eq "94107"
            expect(response.parsed_body["formatted_address"]).to eq "1640 17th St, San Francisco, CA, 94107"
            expect(response.parsed_body["formatted_original_address"]).to eq "1640 17 Street, San Francisco, CA, 94107"
          end
        end
      end

      describe "needs more information" do
        before do
          @params.merge!(street_address: "255 King Street")
        end

        it "calls EasyPost" do
          expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_call_original
          post :verify_shipping_address, params: @params
        end
      end

      describe "unverified address" do
        before do
          @params.merge!(street_address: "16400 17th Street")
        end

        it "calls EasyPost" do
          expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_call_original
          post :verify_shipping_address, params: @params
        end

        it "returns needs more information response" do
          post :verify_shipping_address, params: @params
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["error_message"]).to eq "We are unable to verify your shipping address. Is your address correct?"
        end
      end
    end

    describe "international address" do
      before do
        @params = {
          street_address: "9384 Cardston Ct",
          city: "Burnaby",
          state: "BC",
          zip_code: "V3N 4H4",
          country: "Canada"
        }
      end

      describe "valid address" do
        it "calls EasyPost" do
          expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_call_original
          post :verify_shipping_address, params: @params
        end

        it "returns correct response" do
          post :verify_shipping_address, params: @params
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["street_address"]).to eq "9384 CARDSTON CT"
          expect(response.parsed_body["city"]).to eq "BURNABY"
          expect(response.parsed_body["state"]).to eq "BC"
          expect(response.parsed_body["zip_code"]).to eq "V3N 4H4"
        end
      end

      describe "unverified address" do
        before do
          @params.merge!(street_address: "17th Street")
        end

        it "calls EasyPost" do
          expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_call_original
          post :verify_shipping_address, params: @params
        end

        it "returns needs more information response" do
          post :verify_shipping_address, params: @params
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["error_message"]).to eq "We are unable to verify your shipping address. Is your address correct?"
        end
      end
    end
  end

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
    end
  end
end
