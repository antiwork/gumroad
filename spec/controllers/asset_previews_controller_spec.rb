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

    [Redis::TimeoutError, RedisClient::ReadTimeoutError].each do |error_class|
      it "saves a cover when the retina enqueue raises #{error_class} and recovers on a later render" do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: fixture_file_upload("kFDzu.png", "image/png"), filename: "kFDzu.png"
        )
        error = error_class.new("Redis unavailable")
        allow(ProcessAssetPreviewRetinaWorker).to receive(:perform_async).and_raise(error)
        expect(ErrorNotifier).to receive(:notify).with(error, hash_including(source: "retina_variant_enqueue")).at_least(:once)

        expect do
          post :create, params: { link_id: product.unique_permalink, asset_preview: { signed_blob_id: blob.signed_id }, format: :json }
        end.to change { product.asset_previews.alive.count }.by(1)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)
        preview = product.asset_previews.alive.last
        expect(preview.file.blob).to eq(blob)
        expect(preview.url_from_file).to eq(preview.file.url)
        expect(preview.file.blob.variant_records).to be_empty

        allow(ProcessAssetPreviewRetinaWorker).to receive(:perform_async).and_call_original
        Sidekiq::Testing.inline! { preview.url_from_file }
        expect(preview.reload.retina_variant.url).not_to eq(preview.file.url)
        expect(preview.url_from_file).to eq(preview.retina_variant.url)
      end
    end

    it "saves a cover when reporting a failed retina enqueue also fails" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("kFDzu.png", "image/png"), filename: "kFDzu.png"
      )
      allow(ProcessAssetPreviewRetinaWorker).to receive(:perform_async).and_raise(RedisClient::ReadTimeoutError)
      allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "reporting unavailable")

      post :create, params: { link_id: product.unique_permalink, asset_preview: { signed_blob_id: blob.signed_id }, format: :json }

      expect(response.parsed_body["success"]).to eq(true)
      expect(product.asset_previews.alive.last.file.blob).to eq(blob)
    end

    it "adds a preview if one already exists" do
      allow_any_instance_of(AssetPreview).to receive(:analyze_file).and_return(nil)
      product = create(:product, user: seller, preview: fixture_file_upload("kFDzu.png", "image/png"))
      expect do
        post(:create, params: { link_id: product.unique_permalink, asset_preview: { url: s3_url }, format: :json })
      end.to change { product.asset_previews.alive.count }.by(1)
    end

    it "returns an error for a URL without a host" do
      post(:create, params: { link_id: product.unique_permalink, asset_preview: { url: "https:///path" }, format: :json })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(false)
    end

    it "returns a graceful error when the URL hostname cannot be resolved", skip_ssrf_stub: true do
      allow(SsrfFilter).to receive(:get).and_raise(SsrfFilter::UnresolvedHostname, "Could not resolve hostname")
      post(:create, params: { link_id: product.unique_permalink, asset_preview: { url: "https://unresolvable-host.example" }, format: :json })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to eq("Could not process your preview, please try again.")
    end

    it "returns a graceful error when asset_preview is a scalar instead of a hash" do
      post(:create, params: { link_id: product.unique_permalink, asset_preview: "not-a-hash", format: :json })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to eq("Could not process your preview, please try again.")
    end

    it "returns a graceful error when asset_preview param is absent" do
      post(:create, params: { link_id: product.unique_permalink, format: :json })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to eq("Could not process your preview, please try again.")
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

  describe "as a collaborator on the product" do
    let(:affiliate_user) { create(:user) }
    let!(:collaborator) { create(:collaborator, seller:, affiliate_user:, products: [product]) }

    before do
      sign_out(user_with_role_for_seller)
      sign_in(affiliate_user)
    end

    it "creates a cover" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png"),
        filename: "kFDzu.png"
      )

      post(:create, params: { link_id: product.unique_permalink, asset_preview: { signed_blob_id: blob.signed_id }, format: :json })

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["success"]).to eq(true)
      expect(product.asset_previews.alive.count).to eq(1)
    end

    it "deletes a cover" do
      create(:asset_preview, link: product)

      expect do
        delete(:destroy, params: { link_id: product.unique_permalink, id: product.main_preview.guid })
      end.to change { product.asset_previews.alive.count }.by(-1)

      expect(response.parsed_body["success"]).to eq(true)
    end
  end
end
