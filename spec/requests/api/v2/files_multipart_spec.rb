# frozen_string_literal: true

require "spec_helper"
require "net/http"

describe "Files multipart upload" do
  let(:user) { create(:user) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "edit_products") }

  before do
    host! "test.gumroad.com"
  end

  it "completes a real multipart upload to S3 via presigned part URLs" do
    content = "hello multipart upload"

    post "/api/v2/files/presign",
         params: { access_token: token.token, filename: "hello.txt", file_size: content.bytesize }

    expect(response.parsed_body["success"]).to be true
    upload_id = response.parsed_body["upload_id"]
    key = response.parsed_body["key"]
    part = response.parsed_body["parts"].first
    expect(part["part_number"]).to eq(1)
    expect(part["presigned_url"]).to be_present

    uri = URI.parse(part["presigned_url"])
    req = Net::HTTP::Put.new(uri.request_uri)
    req.body = content

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    s3_response = http.request(req)
    etag = s3_response["ETag"]
    expect(etag).to be_present

    post "/api/v2/files/complete",
         params: {
           access_token: token.token,
           upload_id:,
           key:,
           parts: [{ part_number: 1, etag: }]
         }

    body = response.parsed_body
    expect(body["success"]).to be true
    expect(body["file_url"]).to include(key)
    expect(Aws::S3::Client.new.get_object(bucket: S3_BUCKET, key:).body.read).to eq(content)
  end

  it "completes a real multi-part upload when content spans more than one part" do
    # S3 requires non-last parts to be ≥5 MB. Use PART_SIZE = 5 MB with content of
    # 5 MB + 1 byte so we get exactly 2 parts, both meeting the size constraint.
    part_size = 5 * 1024 * 1024
    stub_const("Api::V2::FilesController::PART_SIZE", part_size)
    content = "x" * (part_size + 1) # 2 parts: 5 MB then 1 byte

    post "/api/v2/files/presign",
         params: { access_token: token.token, filename: "multi.bin", file_size: content.bytesize }

    expect(response.parsed_body["success"]).to be true
    parts_meta = response.parsed_body["parts"]
    expect(parts_meta.count).to eq(2)
    upload_id = response.parsed_body["upload_id"]
    key = response.parsed_body["key"]

    completed_parts = parts_meta.map do |part_meta|
      part_number = part_meta["part_number"]
      chunk = content.byteslice((part_number - 1) * part_size, part_size)

      uri = URI.parse(part_meta["presigned_url"])
      req = Net::HTTP::Put.new(uri.request_uri)
      req.body = chunk

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      s3_response = http.request(req)
      { part_number:, etag: s3_response["ETag"] }
    end

    post "/api/v2/files/complete",
         params: { access_token: token.token, upload_id:, key:, parts: completed_parts }

    body = response.parsed_body
    expect(body["success"]).to be true
    expect(body["file_url"]).to include(key)
    expect(Aws::S3::Client.new.get_object(bucket: S3_BUCKET, key:).body.read).to eq(content)
  end

  it "returns 400 when complete is called with a wrong ETag" do
    content = "hello multipart upload"

    post "/api/v2/files/presign",
         params: { access_token: token.token, filename: "bad.txt", file_size: content.bytesize }

    upload_id = response.parsed_body["upload_id"]
    key = response.parsed_body["key"]
    part_meta = response.parsed_body["parts"].first

    uri = URI.parse(part_meta["presigned_url"])
    req = Net::HTTP::Put.new(uri.request_uri)
    req.body = content
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.request(req)

    post "/api/v2/files/complete",
         params: {
           access_token: token.token,
           upload_id:,
           key:,
           parts: [{ part_number: 1, etag: '"00000000000000000000000000000000"' }]
         }

    expect(response.status).to eq(400)
    expect(response.parsed_body["error"]).to be_present
  end
end
