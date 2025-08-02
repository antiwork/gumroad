# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxesController, type: :controller do
  let(:seller) { create(:user) }

  before do
    sign_in seller
  end

  describe "GET #index" do
    it "returns http success" do
      get :index
      expect(response).to have_http_status(:success)
    end

    it "sets the correct title" do
      get :index
      expect(assigns(:title)).to eq("Payouts")
    end

    it "sets the selected year" do
      get :index, params: { year: "2023" }
      expect(assigns(:selected_year)).to eq(2023)
    end

    it "defaults to current year when no year specified" do
      get :index
      expect(assigns(:selected_year)).to eq(Time.current.year)
    end

    it "assigns tax center props" do
      get :index
      expect(assigns(:tax_center_props)).to be_present
      expect(assigns(:tax_center_props)[:selectedYear]).to be_present
      expect(assigns(:tax_center_props)[:availableYears]).to be_an(Array)
      expect(assigns(:tax_center_props)[:taxDocuments]).to be_an(Array)
      expect(assigns(:tax_center_props)[:taxServices]).to be_an(Array)
      expect(assigns(:tax_center_props)[:faqs]).to be_an(Array)
      expect(assigns(:tax_center_props)[:relatedArticles]).to be_an(Array)
    end
  end

  describe "GET #download_document" do
    it "returns http success for valid document" do
      get :download_document, params: { document_id: "1099k", year: "2023" }
      expect(response).to have_http_status(:redirect)
    end

    it "returns not found for invalid document" do
      get :download_document, params: { document_id: "invalid", year: "2023" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET #download_all" do
    it "returns http success when documents exist" do
      get :download_all, params: { year: "2023" }
      expect(response).to have_http_status(:redirect)
    end
  end

  describe "GET #reseller_certificate" do
    it "returns http success" do
      get :reseller_certificate
      expect(response).to have_http_status(:redirect)
    end
  end
end
