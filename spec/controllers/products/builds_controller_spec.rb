# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::BuildsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let!(:first_build) { create(:product_build, product:, number: 1) }
  let!(:second_build) { create(:product_build, product:, number: 2) }

  include_context "with user signed in as admin for seller"

  before do
    create(:rich_content, entity: product, description: [])
    first_build.promote!
    Feature.activate_user(:product_build_player, seller)
  end

  describe "#index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:policy_klass) { LinkPolicy }
      let(:policy_method) { :update? }
      let(:record) { product }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    it "lists the product's builds, newest first, as the API shows them" do
      get :index, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["builds"]).to eq(JSON.parse([second_build, first_build.reload].to_json))
      expect(response.parsed_body["builds"].map { _1.values_at("number", "status") }).to eq([[2, "uploaded"], [1, "live"]])
    end

    it "returns 404 while the player is off for the seller" do
      Feature.deactivate_user(:product_build_player, seller)

      expect do
        get :index, params: { product_id: product.unique_permalink }, as: :json
      end.to raise_error(ActionController::RoutingError)
    end

    it "refuses another seller's product" do
      other_product = create(:product)
      Feature.activate_user(:product_build_player, other_product.user)

      get :index, params: { product_id: other_product.unique_permalink }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    context "when the current user is a collaborator on the product" do
      let(:affiliate_user) { create(:user) }
      let!(:collaborator) { create(:collaborator, seller:, affiliate_user:, products: [product]) }

      before { sign_in affiliate_user }

      it "lists the product's builds" do
        get :index, params: { product_id: product.unique_permalink }, as: :json

        expect(response.parsed_body["builds"].map { _1["number"] }).to eq([2, 1])
      end
    end
  end

  describe "#create" do
    let(:s3) { Aws::S3::Client.new }

    def upload_zip(owner: seller, filename: "game.zip")
      key = "attachments/#{owner.external_id}/#{SecureRandom.hex}/original/#{filename}"
      s3.put_object(bucket: S3_BUCKET, key:, body: "PK-zip")
      "#{S3_BASE_URL}#{key}"
    end

    it "adds the zip the editor uploaded as the next version, not live" do
      post :create, params: { product_id: product.unique_permalink, url: upload_zip }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["build"]).to include("number" => 3, "status" => "uploaded")
      expect(s3.get_object(bucket: S3_BUCKET, key: product.product_builds.find_by!(number: 3).storage_key).body.read).to eq("PK-zip")
    end

    it "accepts a zip whose name ends in upper case" do
      post :create, params: { product_id: product.unique_permalink, url: upload_zip(filename: "GAME.ZIP") }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["build"]).to include("number" => 3)
    end

    it "refuses a zip from another seller's uploads, with the reason" do
      post :create, params: { product_id: product.unique_permalink, url: upload_zip(owner: create(:user)) }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include(".zip")
      expect(product.product_builds.count).to eq(2)
    end
  end

  describe "#promote" do
    it "makes the build live and supersedes the live one" do
      post :promote, params: { product_id: product.unique_permalink, id: second_build.public_id }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(second_build.reload.status).to eq("live")
      expect(first_build.reload.status).to eq("superseded")
    end

    it "returns 404 for a build of another product" do
      other_build = create(:product_build, product: create(:product, user: seller))

      expect do
        post :promote, params: { product_id: product.unique_permalink, id: other_build.public_id }, as: :json
      end.to raise_error(ActionController::RoutingError)
      expect(other_build.reload.status).to eq("uploaded")
    end
  end
end
