# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe AssetPreviewsController do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:s3_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.png" }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { AssetPreview }
      let(:request_params) { { link_id: product.unique_permalink, asset_preview: { url: s3_url }, format: :json } }
    end

    it "fails if not logged in" do
      sign_out(user_with_role_for_seller)
      expect do
        expect do
          post(:create, params: { link_id: product.id, asset_preview: { url: s3_url } })
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end.to_not change { AssetPreview.count }
    end

    it "adds a preview if one already exists" do
      allow_any_instance_of(AssetPreview).to receive(:analyze_file).and_return(nil)
      product = create(:product, user: seller, preview: fixture_file_upload("kFDzu.png", "image/png"))
      expect do
        post(:create, params: { link_id: product.unique_permalink, asset_preview: { url: s3_url }, format: :json })
      end.to change { product.asset_previews.alive.count }.by(1)
    end

    it "doesn't add a preview if there are too many previews" do
      stub_const("Link::MAX_PREVIEW_COUNT", 1)
      allow_any_instance_of(AssetPreview).to receive(:analyze_file).and_return(nil)
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      create(:asset_preview, link: product)
      expect do
        post(:create, params: { link_id: product.unique_permalink, asset_preview: { url: s3_url }, format: :json })
      end.to_not change { AssetPreview.count }
    end
  end

  describe "DELETE destroy" do
    let!(:asset_preview) { create(:asset_preview, link: product) }

    it_behaves_like "authorize called for action", :post, :destroy do
      let(:record) { asset_preview }
      let(:request_params) { { link_id: product.unique_permalink, id: product.main_preview.guid } }
    end

    it "fails if not logged in" do
      sign_out(user_with_role_for_seller)
      expect do
        expect do
          delete(:destroy, params: { link_id: product.unique_permalink, id: product.main_preview.guid })
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end.to_not change { product.asset_previews.alive.count }
    end

    it "removes a preview" do
      expect do
        delete(:destroy, params: { link_id: product.unique_permalink, id: product.main_preview.guid })
      end.to change { product.asset_previews.alive.count }.from(1).to(0)
      expect(product.main_preview).to be(nil)
    end
  end
end
