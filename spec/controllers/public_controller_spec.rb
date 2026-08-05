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
      expect(controller.send(:page_title)).to eq("API")
      expect(inertia).to render_component("Public/Api")
    end
  end

  describe "GET ping", inertia: true do
    it "succeeds and renders with Inertia" do
      get :ping
      expect(response).to be_successful
      expect(controller.send(:page_title)).to eq("Ping")
      expect(inertia).to render_component("Public/Ping")
    end
  end

  describe "GET charge", inertia: true do
    it "succeeds and renders with Inertia" do
      get :charge
      expect(response).to be_successful
      expect(controller.send(:page_title)).to eq("Why is there a charge on my account?")
      expect(inertia).to render_component("Public/Charge")
    end
  end

  describe "GET license_key_lookup", inertia: true do
    it "succeeds and renders with Inertia" do
      get :license_key_lookup
      expect(response).to be_successful
      expect(controller.send(:page_title)).to eq("What is my license key?")
      expect(inertia).to render_component("Public/LicenseKeyLookup")
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
        expect(controller.send(:page_title)).to eq("Widgets")
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

    it "scopes to the given year when present" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      in_year = create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com", created_at: Time.utc(2024, 6, 1))
      create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com", created_at: Time.utc(2023, 6, 1))

      expect(CustomerMailer).to receive(:grouped_receipt).with([in_year.id]).and_return(mail_double)
      get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com", year: "2024" }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "scopes to the given year and month together, ignoring month without a year" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      in_month = create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com", created_at: Time.utc(2024, 3, 15))
      other_month = create(:purchase, price_cents: 100, fee_cents: 30, card_visual: "**** 4242", email: "edgar@gumroad.com", created_at: Time.utc(2024, 4, 1))

      expect(CustomerMailer).to receive(:grouped_receipt).with([in_month.id]).and_return(mail_double)
      get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com", year: "2024", month: "3" }
      expect(response.parsed_body["success"]).to be(true)

      expect(CustomerMailer).to receive(:grouped_receipt).with(match_array([in_month.id, other_month.id])).and_return(mail_double)
      get :charge_data, params: { last_4: "4242", email: "edgar@gumroad.com", month: "3" }
      expect(response.parsed_body["success"]).to be(true)
    end
  end

  describe "GET license_key_lookup_data" do
    let(:email) { "buyer@example.com" }
    let(:wanted_product) { create(:product, name: "Photo Editor Pro", unique_permalink: "photoed") }
    let(:other_product) { create(:product, name: "Unrelated Course") }
    let!(:other_purchase) { create(:purchase, link: other_product, email:, price_cents: 100, fee_cents: 30) }
    let!(:wanted_purchase) { create(:purchase, link: wanted_product, email:, price_cents: 100, fee_cents: 30) }

    it "returns false when no purchases match the email" do
      get :license_key_lookup_data, params: { email: "nobody@example.com" }
      expect(response.parsed_body["success"]).to be(false)
    end

    it "emails only the purchases matching the product query" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      expect(CustomerMailer).to receive(:grouped_receipt).with([wanted_purchase.id]).and_return(mail_double)
      get :license_key_lookup_data, params: { email:, product_query: "Photo Editor" }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "matches by permalink" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      expect(CustomerMailer).to receive(:grouped_receipt).with([wanted_purchase.id]).and_return(mail_double)
      get :license_key_lookup_data, params: { email:, product_query: "photoed" }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "matches by a pasted product URL" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      expect(CustomerMailer).to receive(:grouped_receipt).with([wanted_purchase.id]).and_return(mail_double)
      get :license_key_lookup_data, params: { email:, product_query: wanted_product.long_url }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "falls back to all purchases, rather than reporting false, when the query matches none of the buyer's purchases" do
      # A non-matching query must respond identically to a matching one — otherwise an
      # unauthenticated caller who knows the email learns whether it bought a given product.
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      expect(CustomerMailer).to receive(:grouped_receipt).with(match_array([other_purchase.id, wanted_purchase.id])).and_return(mail_double)
      get :license_key_lookup_data, params: { email:, product_query: "some product I never bought" }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "emails all purchases when no product query is given" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      expect(CustomerMailer).to receive(:grouped_receipt).with(match_array([other_purchase.id, wanted_purchase.id])).and_return(mail_double)
      get :license_key_lookup_data, params: { email: }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "does not treat LIKE wildcards in the query as wildcards, falling back to all purchases" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)

      expect(CustomerMailer).to receive(:grouped_receipt).with(match_array([other_purchase.id, wanted_purchase.id])).and_return(mail_double)
      get :license_key_lookup_data, params: { email:, product_query: "%" }
      expect(response.parsed_body["success"]).to be(true)
    end

    it "responds identically for a matching and a non-matching product query (no purchase oracle)" do
      get :license_key_lookup_data, params: { email:, product_query: "Photo Editor" }
      matching_body = response.parsed_body

      get :license_key_lookup_data, params: { email:, product_query: "some product I never bought" }
      nonmatching_body = response.parsed_body

      expect(matching_body).to eq(nonmatching_body)
      expect(matching_body["success"]).to be(true)
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
