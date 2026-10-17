# frozen_string_literal: true

require "spec_helper"
require "digest/md5"

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
end
