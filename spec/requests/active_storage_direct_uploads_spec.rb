# frozen_string_literal: true

require "spec_helper"
require "digest/md5"
require "net/http"
require "active_storage/service/disk_service"

describe "POST /rails/active_storage/direct_uploads" do
  let(:blob_params) do
    {
      filename: "cover.png",
      byte_size: 1024,
      checksum: Digest::MD5.base64digest("cover image"),
      content_type: "image/png"
    }
  end

  # The direct-upload route is posted to from a body built in JS, not from a rendered page
  # holding a token.
  around do |example|
    previous_forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    example.run
    ActionController::Base.allow_forgery_protection = previous_forgery
  end

  it "creates a blob for a well-formed reservation" do
    expect do
      post rails_direct_uploads_path, params: { blob: blob_params }, as: :json
    end.to change { ActiveStorage::Blob.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["signed_id"]).to eq(ActiveStorage::Blob.last.signed_id)
  end

  it "answers 400 instead of 500 when a required blob key is missing" do
    expect do
      post rails_direct_uploads_path, params: { blob: blob_params.except(:checksum) }, as: :json
    end.not_to change { ActiveStorage::Blob.count }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("blob must include filename, byte_size and checksum")
  end

  # `permit` drops a key whose value is not a permitted scalar, so a raw `present?` check would let
  # this body through and `create_before_direct_upload!` would still raise for the dropped keyword.
  it "answers 400 instead of 500 when a required blob key is not a scalar" do
    expect do
      post rails_direct_uploads_path, params: { blob: blob_params.merge(filename: ["cover.png"]) }, as: :json
    end.not_to change { ActiveStorage::Blob.count }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("blob must include filename, byte_size and checksum")
  end

  describe "headers stored on the public bucket" do
    def reserve(content_type:, filename: "file.bin", body: "file body")
      post rails_direct_uploads_path, params: {
        blob: { filename:, byte_size: body.bytesize, checksum: Digest::MD5.base64digest(body), content_type: }
      }, as: :json
      expect(response).to have_http_status(:ok)
      response.parsed_body
    end

    def put_object(direct_upload, body, headers: direct_upload["headers"])
      uri = URI(direct_upload["url"])
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Put.new(uri, headers), body)
      end
    end

    def stored_object(json)
      ActiveStorage::Blob.find_signed!(json["signed_id"]).service.bucket.object(json["key"]).tap(&:load)
    end

    ["text/html", "image/svg+xml", "application/xhtml+xml", "text/javascript", "Text/HTML; charset=utf-8", "video/mp4+xml", ""].each do |declared|
      it "serves #{declared.inspect} as a binary attachment" do
        headers = reserve(content_type: declared, filename: "page.html")["direct_upload"]["headers"]

        expect(headers["Content-Type"]).to eq("application/octet-stream")
        expect(headers["Content-Disposition"]).to start_with("attachment; filename=\"page.html\"")
      end
    end

    %w[image/png image/jpeg image/gif image/webp image/avif audio/mpeg audio/x-m4a audio/x-wav video/mp4 video/quicktime video/x-ms-wmv].each do |declared|
      it "keeps #{declared} inline" do
        headers = reserve(content_type: declared)["direct_upload"]["headers"]

        expect(headers["Content-Type"]).to eq(declared)
        expect(headers["Content-Disposition"]).to start_with("inline;")
      end
    end

    it "stores a non-inline type as a binary attachment" do
      body = "<html><body>Hello</body></html>"
      json = reserve(content_type: "text/html", filename: "page.html", body:)

      expect(put_object(json["direct_upload"], body)).to be_a(Net::HTTPOK)
      object = stored_object(json)
      expect(object.content_type).to eq("application/octet-stream")
      expect(object.content_disposition).to start_with("attachment; filename=\"page.html\"")
    end

    {
      "changes the signed Content-Disposition" => ->(headers) { headers.merge("Content-Disposition" => "inline") },
      "drops the signed Content-Disposition" => ->(headers) { headers.except("Content-Disposition") },
      "changes the signed Content-Type" => ->(headers) { headers.merge("Content-Type" => "text/html") },
    }.each do |change, tamper|
      it "refuses an upload that #{change}" do
        body = "<html><body>Hello</body></html>"
        json = reserve(content_type: "text/html", filename: "page.html", body:)
        headers = tamper.call(json["direct_upload"]["headers"])

        expect(put_object(json["direct_upload"], body, headers:)).to be_a(Net::HTTPClientError)
        expect(ActiveStorage::Blob.find_signed!(json["signed_id"]).service.bucket.object(json["key"]).exists?).to be(false)
      end
    end

    it "stores a buyer document as a downloadable attachment and keeps its declared type on the blob" do
      body = "%PDF-1.4 receipt"
      json = reserve(content_type: "application/pdf", filename: "receipt.pdf", body:)

      expect(put_object(json["direct_upload"], body)).to be_a(Net::HTTPOK)
      expect(json["content_type"]).to eq("application/pdf")
      object = stored_object(json)
      expect(object.content_type).to eq("application/octet-stream")
      expect(object.content_disposition).to start_with("attachment; filename=\"receipt.pdf\"")
    end

    it "stores an image inline with its type" do
      body = "png bytes"
      json = reserve(content_type: "image/png", filename: "cover.png", body:)

      expect(put_object(json["direct_upload"], body)).to be_a(Net::HTTPOK)
      object = stored_object(json)
      expect(object.content_type).to eq("image/png")
      expect(object.content_disposition).to start_with("inline; filename=\"cover.png\"")
    end

    it "accepts an inline upload sent without Content-Disposition" do
      body = "png bytes"
      json = reserve(content_type: "image/png", filename: "cover.png", body:)
      headers = json["direct_upload"]["headers"].except("Content-Disposition")

      expect(put_object(json["direct_upload"], body, headers:)).to be_a(Net::HTTPOK)
      expect(stored_object(json).content_type).to eq("image/png")
    end

    it "reserves uploads on services that do not sign the disposition" do
      blob = ActiveStorage::Blob.new(key: "disk-key", filename: "page.html", byte_size: 1, checksum: Digest::MD5.base64digest("x"), content_type: "text/html")
      Dir.mktmpdir do |root|
        allow(blob).to receive(:service).and_return(ActiveStorage::Service::DiskService.new(root:))

        ActiveStorage::Current.set(url_options: { host: "example.com" }) do
          expect(blob.service_url_for_direct_upload).to include("/rails/active_storage/disk/")
        end
        expect(blob.service_headers_for_direct_upload).to eq("Content-Type" => "application/octet-stream")
      end
    end
  end
end
