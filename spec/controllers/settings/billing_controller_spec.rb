# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::BillingController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  before { sign_in(seller) }

  it_behaves_like "authorize called for controller", Settings::BillingPolicy do
    let(:record) { :billing }
  end

  describe "GET show" do
    it "returns http success and renders the Inertia component" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/Billing/Show")
      expect(inertia.props[:countries]).to be_a(Hash)
      expect(inertia.props[:business_id_country_codes]).to include("DE", "FR", "GB")
      expect(inertia.props[:billing_detail][:auto_email_invoice_enabled]).to eq(true)
    end

    it "pre-fills with existing billing details when present" do
      create(
        :billing_detail,
        purchaser: seller,
        full_name: "Alice GmbH",
        business_name: "Acme",
        business_id: "DE123456789",
        country_code: "DE"
      )

      get :show
      expect(inertia.props[:billing_detail][:full_name]).to eq("Alice GmbH")
      expect(inertia.props[:billing_detail][:business_name]).to eq("Acme")
      expect(inertia.props[:billing_detail][:business_id]).to eq("DE123456789")
      expect(inertia.props[:billing_detail][:country_code]).to eq("DE")
    end
  end

  describe "PUT update" do
    let(:valid_params) do
      {
        billing_detail: {
          full_name: "Alice GmbH",
          business_name: "Acme",
          business_id: "DE123456789",
          street_address: "1 Unter den Linden",
          city: "Berlin",
          zip_code: "10115",
          country_code: "DE",
          additional_notes: "",
          auto_email_invoice_enabled: true,
        }
      }
    end

    it "creates a BillingDetail when none exists and redirects with notice" do
      expect { put :update, params: valid_params }.to change(BillingDetail, :count).by(1)

      expect(response).to redirect_to(settings_billing_path)
      expect(flash[:notice]).to eq("Your billing details have been saved.")
      billing_detail = seller.reload.billing_detail
      expect(billing_detail.business_name).to eq("Acme")
      expect(billing_detail.country_code).to eq("DE")
    end

    it "updates the existing BillingDetail instead of creating another" do
      existing = create(:billing_detail, purchaser: seller, full_name: "Old Name")

      expect { put :update, params: valid_params }.not_to change(BillingDetail, :count)

      expect(existing.reload.full_name).to eq("Alice GmbH")
      expect(flash[:notice]).to eq("Your billing details have been saved.")
    end

    it "redirects without persisting when validation fails" do
      expect do
        put :update, params: { billing_detail: valid_params[:billing_detail].merge(full_name: "") }
      end.not_to change(BillingDetail, :count)

      expect(response).to redirect_to(settings_billing_path)
    end
  end
end
