# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::MediaController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  def create_media_file(seller, display_name: "Logo")
    file = PublicFile.new(seller:, resource: seller, display_name:)
    file.file.attach(
      io: File.open(Rails.root.join("spec/support/fixtures/smilie.png")),
      filename: "smilie.png",
      content_type: "image/png",
    )
    file.save!
    file
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    it "rejects account-only tokens even though legacy v2 endpoints accept account as a fallback" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")

      get @action, params: { access_token: token.token }

      expect(response).to have_http_status(:forbidden)
    end

    describe "when logged in with view_profile scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile")
        @params.merge!(access_token: @token.token)
      end

      it "lists only the creator's own alive media files" do
        mine = create_media_file(@user)
        create_media_file(@user, display_name: "Deleted").mark_deleted!
        create_media_file(create(:user), display_name: "Someone else's")

        get @action, params: @params

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["media"].size).to eq(1)
        expect(body["media"].first["id"]).to eq(mine.public_id)
        expect(body["media"].first["url"]).to be_present
        expect(body["media"].first["file_group"]).to eq("image")
      end

      it "does not list a product's public files as account media" do
        product = create(:product, user: @user)
        create(:public_file, :with_audio, seller: @user, resource: product)

        get @action, params: @params

        expect(response.parsed_body["media"]).to eq([])
      end
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    it "rejects account-only tokens even though legacy v2 endpoints accept account as a fallback" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")

      post @action, params: { access_token: token.token, url: "https://example.com/logo.png" }

      expect(response).to have_http_status(:forbidden)
    end

    describe "when logged in with edit_profile scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_profile")
        @params.merge!(access_token: @token.token)
      end

      it "delegates to the service and returns the hosted file" do
        file = create_media_file(@user)
        result = CreatePublicMediaService::Result.new(success: true, public_file: file)
        expect(CreatePublicMediaService).to receive(:new)
          .with(seller: @user, url: "https://example.com/logo.png", signed_blob_id: nil, name: "My logo")
          .and_return(instance_double(CreatePublicMediaService, process: result))

        post @action, params: @params.merge(url: "https://example.com/logo.png", name: "My logo")

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["media"]["id"]).to eq(file.public_id)
        expect(body["media"]["url"]).to be_present
      end

      it "returns the service's error message on failure" do
        result = CreatePublicMediaService::Result.new(success: false, error_message: "Only image files can be uploaded.")
        allow(CreatePublicMediaService).to receive(:new).and_return(instance_double(CreatePublicMediaService, process: result))

        post @action, params: @params.merge(url: "https://example.com/file.zip")

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to match(/only image/i)
      end

      it "rejects uploads from a suspended seller with a 403 and never calls the service" do
        @user.update!(user_risk_state: "suspended_for_fraud")
        expect(CreatePublicMediaService).not_to receive(:new)

        post @action, params: @params.merge(url: "https://example.com/logo.png")

        expect(response).to have_http_status(:forbidden)
        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Your account is not active.")
      end

      it "rejects uploads from a deleted (closed) account with a 403 and never calls the service" do
        @user.update!(deleted_at: Time.current)
        expect(CreatePublicMediaService).not_to receive(:new)

        post @action, params: @params.merge(url: "https://example.com/logo.png")

        expect(response).to have_http_status(:forbidden)
        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Your account is not active.")
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @action = :destroy
      @params = { id: "abcdef0123456789" }
    end

    it_behaves_like "authorized oauth v1 api method"

    it "rejects account-only tokens even though legacy v2 endpoints accept account as a fallback" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      file = create_media_file(@user)

      delete @action, params: { access_token: token.token, id: file.public_id }

      expect(response).to have_http_status(:forbidden)
      expect(file.reload).to be_alive
    end

    describe "when logged in with edit_profile scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_profile")
        @params.merge!(access_token: @token.token)
      end

      it "deletes the creator's media file and purges its blob" do
        file = create_media_file(@user)

        delete @action, params: @params.merge(id: file.public_id)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload).to be_deleted
      end

      it "404s for another seller's file" do
        file = create_media_file(create(:user))

        delete @action, params: @params.merge(id: file.public_id)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to match(/not found/i)
        expect(file.reload).to be_alive
      end

      it "still lets a suspended seller delete their media (deletion is remediation, not hosting)" do
        file = create_media_file(@user)
        @user.update!(user_risk_state: "suspended_for_fraud")

        delete @action, params: @params.merge(id: file.public_id)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload).to be_deleted
      end
    end
  end
end
