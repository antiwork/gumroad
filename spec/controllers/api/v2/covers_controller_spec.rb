# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::CoversController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = { link_id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "adds a file-based cover from signed_blob_id" do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png"),
          filename: "kFDzu.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["covers"]).to be_an(Array)
        expect(body["covers"].length).to eq(1)
        expect(body["main_cover_id"]).to be_present
        expect(@product.reload.asset_previews.alive.count).to eq(1)
      end

      it "adds a URL-based cover", :vcr do
        post @action, params: @params.merge(url: "https://www.youtube.com/watch?v=qKebcV1jv3A")

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["covers"]).to be_an(Array)
        expect(body["covers"].length).to eq(1)
        expect(@product.reload.asset_previews.alive.count).to eq(1)
      end

      it "returns error for invalid signed_blob_id" do
        post @action, params: @params.merge(signed_blob_id: "invalid-blob-id")

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("The signed_blob_id is invalid or expired.")
      end

      it "returns the correct main_cover_id when covers already exist" do
        existing_cover = create(:asset_preview, link: @product)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png"),
          filename: "kFDzu.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["covers"].length).to eq(2)
        expect(body["main_cover_id"]).to eq(existing_cover.guid)
      end

      it "returns error when neither signed_blob_id nor url is provided" do
        post @action, params: @params

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a signed_blob_id or url.")
      end

      it "respects the maximum cover count" do
        Link::MAX_PREVIEW_COUNT.times do
          create(:asset_preview, link: @product)
        end

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png"),
          filename: "kFDzu.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to include("limit of #{Link::MAX_PREVIEW_COUNT} previews")
      end
    end

    it "grants access with the account scope" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png"),
        filename: "kFDzu.png"
      )
      blob.analyze

      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      post @action, params: @params.merge(access_token: token.token, signed_blob_id: blob.signed_id)
      expect(response).to be_successful
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @cover = create(:asset_preview, link: @product)
      @action = :destroy
      @params = { link_id: @product.external_id, id: @cover.guid }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "deletes the cover" do
        delete @action, params: @params

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["covers"]).to be_an(Array)
        expect(body["covers"].length).to eq(0)
        expect(@product.reload.asset_previews.alive.count).to eq(0)
      end

      it "returns the remaining covers and main_cover_id after deletion" do
        second_cover = create(:asset_preview, link: @product)

        delete @action, params: @params

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["covers"].length).to eq(1)
        expect(body["main_cover_id"]).to eq(second_cover.guid)
      end

      it "returns error when cover is not found" do
        delete @action, params: @params.merge(id: "nonexistent")

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("The cover was not found.")
      end
    end
  end
end
