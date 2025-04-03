# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ImportedCustomersController do
  let(:seller) { create(:named_user) }

  describe "GET index" do
    include_context "with user signed in as admin for seller"

    before do
      @product = create(:product, user: seller)
      35.times do
        create(:purchase, link: @product)
      end
      35.times do
        create(:imported_customer, link_id: @product.id, importing_user: seller)
      end
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { ImportedCustomer }
    end

    it "returns the correct number of imported customers on first page" do
      get :index, params: { link_id: @product.unique_permalink, page: 0 }
      expect(response.parsed_body["customers"].length).to eq 20
      expect(response.parsed_body["begin_loading_imported_customers"]).to eq true
    end

    it "returns the correct number of imported customers on last page" do
      get :index, params: { link_id: @product.unique_permalink, page: 1 }
      expect(response.parsed_body["customers"].length).to eq 15
      expect(response.parsed_body["begin_loading_imported_customers"]).to eq true
    end
  end

  describe "DELETE destroy" do
    include_context "with user signed in as admin for seller"

    let(:imported_customer) { create(:imported_customer, importing_user: seller) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { imported_customer }
      let(:request_params) { { id: imported_customer.external_id } }
    end
  end
end
