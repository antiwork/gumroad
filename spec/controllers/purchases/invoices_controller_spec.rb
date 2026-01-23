# frozen_string_literal: true

require "spec_helper"

describe Purchases::InvoicesController do
  before do
    @purchase = create(:free_purchase)
  end

  describe "GET confirm" do
    it "renders the confirmation page" do
      get :confirm, params: { id: @purchase.external_id }

      expect(response).to be_successful
    end
  end

  describe "GET new" do
    it "redirects to confirm page when email is blank" do
      get :new, params: { id: @purchase.external_id }

      expect(response).to redirect_to(confirm_generate_invoice_path(@purchase.external_id))
      expect(flash[:warning]).to eq("Please enter the purchase's email address to generate the invoice.")
    end

    it "redirects to confirm page when email is incorrect" do
      get :new, params: { id: @purchase.external_id, email: "wrong@example.com" }

      expect(response).to redirect_to(confirm_generate_invoice_path(@purchase.external_id))
      expect(flash[:alert]).to eq("Incorrect email address. Please try again.")
    end

    it "renders the invoice generation page when email is correct" do
      get :new, params: { id: @purchase.external_id, email: @purchase.email }

      expect(response).to be_successful
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :new, params: { id: @purchase.external_id, email: @purchase.email }

      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end
  end

  describe "POST create" do
    let(:valid_params) do
      {
        id: @purchase.external_id,
        email: @purchase.email,
        full_name: "John Doe",
        street_address: "123 Main St",
        city: "San Francisco",
        state: "CA",
        zip_code: "94102",
        country_code: "US"
      }
    end

    it "redirects to confirm page when email is blank" do
      post :create, params: valid_params.except(:email)

      expect(response).to redirect_to(confirm_generate_invoice_path(@purchase.external_id))
    end

    it "redirects to confirm page when email is incorrect" do
      post :create, params: valid_params.merge(email: "wrong@example.com")

      expect(response).to redirect_to(confirm_generate_invoice_path(@purchase.external_id))
    end

    it "returns JSON response" do
      post :create, params: valid_params

      expect(response).to be_successful
      expect(response.content_type).to include("application/json")
    end
  end
end
