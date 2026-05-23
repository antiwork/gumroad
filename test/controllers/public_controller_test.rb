# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class PublicControllerTest < ActionController::TestCase
  self.described_class = PublicController
  tests PublicController



  context_ PublicController, type: :controller, inertia: true do
    render_views

    let!(:demo_product) { create(:product, unique_permalink: "demo") }

  context_ "GET api", inertia: true do
  test "succeeds and renders with Inertia" do
        get :api
        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("API")
        expect(inertia).to render_component("Public/Api")
      end
    end

  context_ "GET ping", inertia: true do
  test "succeeds and renders with Inertia" do
        get :ping
        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("Ping")
        expect(inertia).to render_component("Public/Ping")
      end
    end

  context_ "GET charge", inertia: true do
  test "succeeds and renders with Inertia" do
        get :charge
        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("Why is there a charge on my account?")
        expect(inertia).to render_component("Public/Charge")
      end
    end

  context_ "GET license_key_lookup", inertia: true do
  test "succeeds and renders with Inertia" do
        get :license_key_lookup
        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("What is my license key?")
        expect(inertia).to render_component("Public/LicenseKeyLookup")
      end
    end

  context_ "GET home" do
  context_ "when not authenticated" do
  test "redirects to the login page" do
          get :home

          expect(response).to redirect_to(login_path)
        end
      end

  context_ "when authenticated" do
        before do
          sign_in create(:user)
        end

  test "redirects to the dashboard page" do
          get :home

          expect(response).to redirect_to(dashboard_path)
        end
      end
    end

  context_ "GET widgets" do
  context_ "with user signed in as admin for seller" do
        let(:seller) { create(:named_seller) }

        include_context "with user signed in as admin for seller"

  test "renders the inertia page with correct component and title" do
          get :widgets

          expect(response).to be_successful
          expect(inertia).to render_component("Public/Widgets")
          expect(controller.send(:page_title)).to eq("Widgets")
        end
      end
    end

  context_ "POST charge_data" do
  test "returns correct information if no purchases match" do
        get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com" }
        expect(response.parsed_body["success"]).to be(false)
      end

  test "returns correct information if a purchase matches" do
        create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com")
        get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com" }
        expect(response.parsed_body["success"]).to be(true)
      end

  test "returns only the successful and gift_receiver_purchase_successful purchases that match the criteria" do
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

  context_ "paypal_charge_data" do
  context_ "when there is no invoice_id value passed" do
        let(:params) { { invoice_id: nil } }

  test "returns false" do
          get(:paypal_charge_data, params:)
          expect(response.parsed_body["success"]).to be(false)
          expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
        end
      end

  context_ "with a valid invoice_id value" do
        let(:purchase) { create(:purchase, price_cents: 100, fee_cents: 30) }
        let(:params) { { invoice_id: purchase.external_id } }

  test "returns correct information and enqueues job for sending the receipt" do
          get(:paypal_charge_data, params:)
          expect(response.parsed_body["success"]).to be(true)
          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
        end

  context_ "when the product has stampable PDFs" do
          before do
            allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(true)
          end

  test "enqueues job for sending the receipt on the default queue" do
            get(:paypal_charge_data, params:)
            expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("default")
          end
        end
      end
    end
  end
end
