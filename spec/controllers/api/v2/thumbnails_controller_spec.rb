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

      it "attaches a thumbnail from a URL" do
        url = "https://example.com/assets/thumbnail.png?token=abc&w=600"
        stub_remote_file(url, "smilie.png", "image/png")

        post @action, params: @params.merge(url:)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["thumbnail"]["url"]).to be_present
        expect(body["thumbnail"]["guid"]).to be_present
        expect(@product.reload.thumbnail).to be_alive
        expect(@product.thumbnail.file.blob.filename.to_s).to eq("thumbnail.png")
        expect(@product.thumbnail.file.blob.metadata.slice("width", "height")).to eq("width" => 1006, "height" => 1006)
        expect(@product.thumbnail.unsplash_url).to be_nil
        expect(SsrfFilter).to have_received(:get).with(url)
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

      it "replaces an existing thumbnail from a URL" do
        existing = create(:thumbnail, product: @product)
        old_guid = existing.guid
        old_blob = existing.file.blob
        url = "https://example.com/replacement.png"
        stub_remote_file(url, "smilie.png", "image/png")

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { Thumbnail.count }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(@product.reload.thumbnail.guid).to eq(old_guid)
        expect(@product.thumbnail.file.blob).not_to eq(old_blob)
        expect(@product.thumbnail.file.blob.filename.to_s).to eq("replacement.png")
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

      it "returns validation errors for too-small remote files" do
        url = "https://example.com/small.png"
        stub_remote_file(url, "test-small.png", "image/png")

        post @action, params: @params.merge(url:)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please try again.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "returns validation errors for non-square remote files" do
        url = "https://example.com/non-square.png"
        stub_remote_file(url, "kFDzu.png", "image/png")

        post @action, params: @params.merge(url:)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please upload a square thumbnail.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "returns validation errors for oversized remote files and purges the downloaded blob" do
        url = "https://example.com/large.jpeg"
        stub_remote_file(url, "error_file.jpeg", "image/jpeg")

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { ActiveStorage::Blob.count }

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "rejects remote files with content length above the thumbnail limit before creating a blob" do
        url = "https://example.com/large.jpeg"
        stub_remote_file(url, "smilie.png", "image/jpeg", content_length: Thumbnail::MAX_FILE_SIZE + 1)

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { ActiveStorage::Blob.count }

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "stops downloading remote files when the streamed body exceeds the thumbnail limit" do
        url = "https://example.com/large.jpeg"
        stub_remote_file(url, "smilie.png", "image/jpeg", chunks: ["a" * Thumbnail::MAX_FILE_SIZE, "a"])

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { ActiveStorage::Blob.count }

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "stops downloading redirect response bodies when they exceed the thumbnail limit" do
        url = "https://example.com/redirecting-thumbnail.png"
        redirect_response = remote_file_response("blah.txt", "text/plain", chunks: ["a" * Thumbnail::MAX_FILE_SIZE, "a"], redirect: true)
        final_response = remote_file_response("smilie.png", "image/png")
        allow(SsrfFilter).to receive(:get).with(url) do |&block|
          block.call(redirect_response)
          block.call(final_response)
          final_response
        end

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { ActiveStorage::Blob.count }

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "does not count discarded redirect response bodies against the final image size" do
        url = "https://example.com/redirecting-thumbnail.png"
        redirect_response = remote_file_response("blah.txt", "text/plain", chunks: ["a" * Thumbnail::MAX_FILE_SIZE], redirect: true)
        final_response = remote_file_response("smilie.png", "image/png")
        allow(SsrfFilter).to receive(:get).with(url) do |&block|
          block.call(redirect_response)
          block.call(final_response)
          final_response
        end

        post @action, params: @params.merge(url:)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(@product.reload.thumbnail).to be_alive
        expect(@product.thumbnail.file.blob.filename.to_s).to eq("redirecting-thumbnail.png")
        expect(@product.thumbnail.file.blob.byte_size).to eq(File.size(Rails.root.join("spec", "support", "fixtures", "smilie.png")))
      end

      it "purges the downloaded blob and keeps the existing thumbnail when analysis fails" do
        existing = create(:thumbnail, product: @product)
        old_blob = existing.file.blob
        url = "https://example.com/thumbnail.png"
        stub_remote_file(url, "smilie.png", "image/png")
        allow_any_instance_of(ActiveStorage::Blob).to receive(:analyze).and_raise(Net::ReadTimeout)

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { ActiveStorage::Blob.count }

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please try again.")
        expect(@product.reload.thumbnail.file.blob).to eq(old_blob)
      end

      it "returns processing errors for non-success remote responses without creating a blob" do
        url = "https://example.com/not-found.png"
        stub_remote_file(url, "blah.txt", "text/html", response_class: Net::HTTPNotFound)

        expect do
          post @action, params: @params.merge(url:)
        end.not_to change { ActiveStorage::Blob.count }

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please try again.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "returns processing errors for non-image remote files" do
        url = "https://example.com/not-image.txt"
        stub_remote_file(url, "blah.txt", "text/plain")

        post @action, params: @params.merge(url:)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please try again.")
        expect(@product.reload.thumbnail).to be_nil
      end

      it "returns error when neither signed_blob_id nor url is provided" do
        post @action, params: @params

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a signed_blob_id or url.")
      end

      it "returns error for invalid signed_blob_id" do
        post @action, params: @params.merge(signed_blob_id: "invalid-blob-id")

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("The signed_blob_id is invalid or expired.")
      end

      it "returns error for invalid URLs" do
        post @action, params: @params.merge(url: "ftp://example.com/thumbnail.png")

        expect(response).to have_http_status(:bad_request)
        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a valid public image URL.")
      end

      it "returns error for unresolved URLs" do
        url = "https://nonexistent.example.com/thumbnail.png"
        allow(SsrfFilter).to receive(:get).with(url).and_raise(SsrfFilter::UnresolvedHostname)

        post @action, params: @params.merge(url:)

        expect(response).to have_http_status(:bad_request)
        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a valid public image URL.")
      end

      it "returns error for URLs with too many redirects" do
        url = "https://example.com/redirect-loop.png"
        allow(SsrfFilter).to receive(:get).with(url).and_raise(SsrfFilter::TooManyRedirects)

        post @action, params: @params.merge(url:)

        expect(response).to have_http_status(:bad_request)
        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a valid public image URL.")
      end

      it "returns error for blocked internal URLs" do
        url = "http://127.0.0.1/thumbnail.png"
        allow(SsrfFilter).to receive(:get).with(url).and_raise(SsrfFilter::PrivateIPAddress)

        post @action, params: @params.merge(url:)

        expect(response).to have_http_status(:bad_request)
        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Please provide a valid public image URL.")
      end

      it "returns processing errors when the remote file cannot be downloaded" do
        url = "https://example.com/missing.png"
        allow(SsrfFilter).to receive(:get).with(url).and_raise(SocketError)

        post @action, params: @params.merge(url:)

        body = response.parsed_body
        expect(body["success"]).to be(false)
        expect(body["message"]).to eq("Could not process your thumbnail, please try again.")
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

  def stub_remote_file(url, fixture_name, content_type, content_length: nil, chunks: nil, response_class: Net::HTTPOK)
    response = remote_file_response(fixture_name, content_type, content_length:, chunks:, response_class:)

    allow(SsrfFilter).to receive(:get).with(url).and_yield(response).and_return(response)
  end

  def remote_file_response(fixture_name, content_type, content_length: nil, chunks: nil, response_class: Net::HTTPOK, redirect: false)
    response_class = Net::HTTPRedirection if redirect

    Class.new(response_class) do
      define_method(:initialize) do |fixture_name, content_type, content_length, chunks|
        if is_a?(Net::HTTPResponse)
          code = redirect ? "302" : Net::HTTPResponse::CODE_TO_OBJ.key(response_class)
          super("1.1", code, code)
        end

        @body = File.binread(Rails.root.join("spec", "support", "fixtures", fixture_name))
        @content_type = content_type
        @content_length = content_length
        @chunks = chunks
      end

      attr_reader :content_type

      def [](header)
        @content_length if header.downcase == "content-length"
      end

      def read_body
        (@chunks || [@body]).each { yield _1 }
      end
    end.new(fixture_name, content_type, content_length, chunks)
  end
end
