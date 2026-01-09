# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe PublicController, type: :controller, inertia: true do
  render_views

  let!(:demo_product) { create(:product, unique_permalink: "demo") }

  describe "GET api", inertia: true do
    it "succeeds and renders with Inertia" do
      get :api
      expect(response).to be_successful
      expect(assigns(:title)).to eq("API")
      expect(inertia).to render_component("Public/Api")
    end
  end

  describe "GET ping", inertia: true do
    it "succeeds and renders with Inertia" do
      get :ping
      expect(response).to be_successful
      expect(assigns(:title)).to eq("Ping")
      expect(inertia).to render_component("Public/Ping")
    end
  end

  describe "GET home" do
    context "when not authenticated" do
      it "redirects to the login page" do
        get :home

        expect(response).to redirect_to(login_path)
      end
    end

    context "when authenticated" do
      before do
        sign_in create(:user)
      end

      it "redirects to the dashboard page" do
        get :home

        expect(response).to redirect_to(dashboard_path)
      end
    end
  end

  describe "GET widgets" do
    context "with user signed in as admin for seller" do
      let(:seller) { create(:named_seller) }

      include_context "with user signed in as admin for seller"

      it "renders the inertia page with correct component and title" do
        get :widgets

        expect(response).to be_successful
        expect(inertia).to render_component("Public/Widgets")
        expect(assigns(:title)).to eq("Widgets")
      end
    end
  end

  describe "POST charge_data" do
    it "returns correct information if no purchases match" do
      get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com" }
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns correct information if a purchase matches" do
      create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com")
      get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com" }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "returns only the successful and gift_receiver_purchase_successful purchases that match the criteria" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      purchase = create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com")
      create(:purchase, purchase_state: "preorder_authorization_successful", price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com")
      gift_receiver_purchase = create(:purchase, purchase_state: "gift_receiver_purchase_successful", price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com")
      create(:purchase, purchase_state: "failed", price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com")

      expect(CustomerMailer).to receive(:grouped_receipt).with([purchase.id, gift_receiver_purchase.id]).and_return(mail_double)
      get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com" }
      expect(response.parsed_body["success"]).to be(true)
    end
  end

  describe "paypal_charge_data" do
    context "when there is no invoice_id value passed" do
      let(:params) { { invoice_id: nil } }

      it "returns false" do
        get(:paypal_charge_data, params:)
        expect(response.parsed_body["success"]).to be(false)
        expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
      end
    end

    context "with a valid invoice_id value" do
      let(:purchase) { create(:purchase, price_cents: 100, fee_cents: 30) }
      let(:params) { { invoice_id: purchase.external_id } }

      it "returns correct information and enqueues job for sending the receipt" do
        get(:paypal_charge_data, params:)
        expect(response.parsed_body["success"]).to be(true)
        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
      end

      context "when the product has stampable PDFs" do
        before do
          allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(true)
        end

        it "enqueues job for sending the receipt on the default queue" do
          get(:paypal_charge_data, params:)
          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("default")
        end
      end
    end
  end
end
