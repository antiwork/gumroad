# frozen_string_literal: true

require "spec_helper"

describe "PUT /api/v2/products/:id files[] parameters", type: :request do
  let(:seller) { create(:user) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "edit_products") }
  let(:product) { create(:product, user: seller, name: "Original") }

  before { host! "test.gumroad.com" }

  def new_file_url(name: "new_file.pdf")
    s3_key = "attachments/#{seller.external_id}/#{SecureRandom.hex}/original/#{name}"
    Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key).put(body: "test content")
    "#{S3_BASE_URL}#{s3_key}"
  end

  def put_product(files: nil, **params)
    body = { access_token: token.token }.merge(params)
    body[:files] = files unless files.nil?
    put "/api/v2/products/#{product.external_id}", params: body, as: :json
  end

  describe "unknown keys" do
    # GUMROAD-1KG: the key reached ProductFile#update! and raised
    # ActiveModel::UnknownAttributeError, which save_files!'s RecordInvalid
    # rescue does not catch, so the whole request 500'd.
    it "names the unknown key instead of raising UnknownAttributeError" do
      put_product(files: [{ type: "archive", url: new_file_url }], name: "Updated")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to eq("'type' is not an accepted parameter on files[]; it is not a writable ProductFile attribute.")
      expect(product.reload.name).to eq("Original")
      expect(product.product_files.alive).to be_empty
    end

    it "rejects an unknown key on an entry that keeps an existing file" do
      file = create(:product_file, link: product, display_name: "Old")

      put_product(files: [{ id: file.external_id, url: file.url, type: "archive" }])

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("'type' is not an accepted parameter on files[]")
      expect(file.reload.display_name).to eq("Old")
    end

    it "rejects database ownership and lifecycle fields instead of mass-assigning them" do
      file = create(:product_file, link: product, display_name: "Old")

      %i[link_id installment_id deleted_at flags json_data].each do |field|
        put_product(files: [{ id: file.external_id, url: file.url, field => 1 }])

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("'#{field}' is not an accepted parameter on files[]")
      end

      expect(file.reload.link_id).to eq(product.id)
      expect(file.deleted_at).to be_nil
      expect(file.flags).to eq(0)
    end

    it "leaves the existing id/url rejection in front of the key check" do
      put_product(files: [{ type: "archive" }])

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("must reference an existing file by id or include a url")
    end
  end

  it "still accepts an existing file by id plus a new file by url" do
    existing = create(:product_file, link: product, display_name: "Old")
    Aws::S3::Resource.new.bucket(S3_BUCKET).object(existing.s3_key).put(body: "test content")

    put_product(files: [
                  { id: existing.external_id, url: existing.url, display_name: "Renamed", description: "Notes", position: 1 },
                  { external_id: "cli-upload-temp", url: new_file_url, display_name: "New File" },
                ], name: "Updated")

    expect(response.parsed_body["success"]).to be(true)
    mapped_id = response.parsed_body.dig("file_id_mappings", "cli-upload-temp")
    expect(mapped_id).to be_present
    expect(product.reload.name).to eq("Updated")
    expect(existing.reload.display_name).to eq("Renamed")
    expect(product.product_files.alive.map(&:external_id)).to contain_exactly(existing.external_id, mapped_id)
  end

  it "still accepts an id-only entry as keep-unchanged" do
    file = create(:product_file, link: product, display_name: "Keep")

    put_product(files: [{ id: file.external_id }])

    expect(response.parsed_body["success"]).to be(true)
    expect(file.reload.display_name).to eq("Keep")
  end

  it "keeps rejecting the internal 'modified' flag with its own message" do
    file = create(:product_file, link: product, display_name: "Old")

    put_product(files: [{ id: file.external_id, url: file.url, modified: "false", display_name: "New" }])

    expect(response.parsed_body["success"]).to be(false)
    expect(response.parsed_body["message"]).to eq("'modified' is not an accepted parameter on files[]; it is an internal save-path flag.")
    expect(file.reload.display_name).to eq("Old")
  end

  # LinkPolicy#product_permitted_attributes — the key set the product editor sends.
  it "accepts the product editor's files[] key set" do
    file = create(:product_file, link: product, display_name: "Old")

    put_product(files: [{
                  id: file.external_id,
                  url: file.url,
                  display_name: "Editor name",
                  description: "Editor notes",
                  folder_id: nil,
                  size: file.size,
                  position: 0,
                  isbn: nil,
                  extension: "pdf",
                  stream_only: false,
                  pdf_stamp_enabled: false,
                  hide_kindle_and_read_buttons: false,
                  file_size: 1234,
                  subtitle_files: [],
                  thumbnail: nil,
                }])

    expect(response.parsed_body["success"]).to be(true)
    expect(file.reload.display_name).to eq("Editor name")
  end

  it "accepts file metadata from GET with the canonical upload URL" do
    file = create(:product_file, link: product, display_name: "Old")
    Aws::S3::Resource.new.bucket(S3_BUCKET).object(file.s3_key).put(body: "test content")

    get "/api/v2/products/#{product.external_id}", params: { access_token: token.token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["success"]).to be(true)
    echo = response.parsed_body.fetch("product").fetch("files").sole
    expect(echo.keys).to include("filetype", "filegroup")
    # GET returns a signed download URL; PUT requires the retained upload URL.
    echo["url"] = file.url
    echo["name"] = "Renamed"

    put_product(files: [echo])

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["success"]).to be(true)
    expect(file.reload.display_name).to eq("Renamed")
  end

  it "ignores client file classifications when attaching an upload" do
    put_product(files: [{ url: new_file_url, filetype: "link", filegroup: "link" }])

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["success"]).to be(true)
    file = product.product_files.alive.sole
    expect(file.filetype).to eq("pdf")
    expect(file.filegroup).to eq("document")
  end

  # The editor serializer includes derived fields that SaveFilesService drops.
  it "accepts an entry carrying the keys ProductFile#as_json emits" do
    file = create(:product_file, link: product)
    echo = file.as_json.transform_keys(&:to_s).slice(
      "file_name", "display_name", "description", "extension", "file_size", "pagelength", "duration",
      "is_pdf", "pdf_stamp_enabled", "hide_kindle_and_read_buttons", "is_streamable", "stream_only",
      "width", "height", "is_transcoding_in_progress", "id", "attached_product_name", "subtitle_files",
      "url", "isbn", "thumbnail", "status"
    )
    expect(echo.keys).to include("status", "is_pdf", "attached_product_name", "file_size", "is_transcoding_in_progress")

    put_product(files: [echo])

    expect(response.parsed_body["success"]).to be(true)
    expect(file.reload.alive?).to be(true)
  end
end
