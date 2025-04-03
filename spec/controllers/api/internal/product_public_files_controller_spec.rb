# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::ProductPublicFilesController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    let(:blob) do
      ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("test.mp3", "audio/mpeg"),
        filename: "test.mp3"
      )
    end
    let(:params) do
      {
        product_id: product.external_id,
        signed_blob_id: blob.signed_id
      }
    end

    it_behaves_like "authentication required for action", :post, :create

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Link }
      let(:request_params) { params }
    end

    it "creates a public file" do
      expect do
        post :create, params:, format: :json
      end.to change(product.reload.public_files, :count).by(1)

      expect(response).to be_successful
      public_file = product.public_files.last
      expect(public_file.resource).to eq(product)
      expect(public_file.seller).to eq(seller)
      expect(public_file.file_type).to eq("mp3")
      expect(public_file.file_group).to eq("audio")
      expect(public_file.original_file_name).to eq("test.mp3")
      expect(public_file.display_name).to eq("test")
      expect(public_file.file.attached?).to be(true)
      expect(response.parsed_body).to eq({ "success" => true, "id" => public_file.public_id })
    end

    it "returns error if file fails to save" do
      allow_any_instance_of(PublicFile).to receive(:save).and_return(false)
      allow_any_instance_of(PublicFile).to receive(:errors).and_return(double(full_messages: ["Error message"]))

      expect do
        post :create, params:, format: :json
      end.not_to change(PublicFile, :count)

      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "success" => false, "error" => "Error message" })
    end

    it "returns 404 if product does not exist" do
      params[:product_id] = "nonexistent"

      expect do
        post :create, params:, format: :json
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns 404 if product does not belong to seller" do
      other_product = create(:product)
      params[:product_id] = other_product.external_id

      expect do
        post :create, params:, format: :json
      end.to raise_error(ActionController::RoutingError)
    end
  end
end
