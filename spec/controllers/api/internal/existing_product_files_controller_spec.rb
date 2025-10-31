# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"
require "shared_examples/with_workflow_form_context"

describe Api::Internal::ExistingProductFilesController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index do
      let(:request_params) { { product_id: create(:product).unique_permalink } }
    end

    it "returns 404 if the product does not belong to the signed in seller" do
      expect do
        get :index, format: :json, params: { product_id: create(:product).unique_permalink }
      end.to raise_error(ActionController::RoutingError)
    end

    let(:product) { create(:product_with_pdf_file, user: seller) }
    let(:product_files) do
      product_file = product.product_files.first
      [{ attached_product_name: product.name,  extension: "PDF", file_name: "Display Name", display_name: "Display Name", description: "Description", file_size: 50, id: product_file.external_id, is_pdf: true, pdf_stamp_enabled: false, is_streamable: false, stream_only: false, is_transcoding_in_progress: false, isbn: nil, pagelength: 3, duration: nil, subtitle_files: [], url: product_file.url, thumbnail: nil, status: { type: "saved" } }]
    end

    it "returns existing files for the product" do
      get :index, format: :json, params: { product_id: product.unique_permalink }

      expect(response).to be_successful
      expect(response.parsed_body.deep_symbolize_keys).to eq({ existing_files: product_files })
    end
  end
end
