# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::ThumbnailsController do
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

      it "attaches a thumbnail from signed_blob_id" do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"),
          filename: "smilie.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["thumbnail"]).to be_present
        expect(body["thumbnail"]["guid"]).to be_present
        expect(@product.reload.thumbnail).to be_alive
      end

      it "replaces an existing thumbnail" do
        existing = create(:thumbnail, product: @product)
        old_guid = existing.guid

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"),
          filename: "smilie.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(@product.reload.thumbnail.guid).to eq(old_guid)
        expect(@product.thumbnail).to be_alive
      end

      it "returns validation errors for invalid files" do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png"),
          filename: "kFDzu.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to be_present
      end

      it "returns error when signed_blob_id is not provided" do
        post @action, params: @params

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a signed_blob_id.")
      end

      it "returns error for invalid signed_blob_id" do
        post @action, params: @params.merge(signed_blob_id: "invalid-blob-id")

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("The signed_blob_id is invalid or expired.")
      end

      it "revives a previously deleted thumbnail" do
        thumbnail = create(:thumbnail, product: @product)
        thumbnail.mark_deleted!
        expect(@product.reload.thumbnail).not_to be_alive

        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"),
          filename: "smilie.png"
        )
        blob.analyze

        post @action, params: @params.merge(signed_blob_id: blob.signed_id)

        expect(response).to be_successful
        expect(@product.reload.thumbnail).to be_alive
      end
    end

    it "grants access with the account scope" do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"),
        filename: "smilie.png"
      )
      blob.analyze

      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      post @action, params: @params.merge(access_token: token.token, signed_blob_id: blob.signed_id)
      expect(response).to be_successful
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @thumbnail = create(:thumbnail, product: @product)
      @action = :destroy
      @params = { link_id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "deletes the thumbnail" do
        delete @action, params: @params

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(@product.reload.thumbnail).not_to be_alive
      end

      it "returns error when no thumbnail exists" do
        @thumbnail.mark_deleted!

        delete @action, params: @params

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("The thumbnail was not found.")
      end
    end
  end
end
