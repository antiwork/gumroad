# frozen_string_literal: true

require "spec_helper"

describe "Game builds API" do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "edit_products") }
  let(:s3) { Aws::S3::Client.new }

  before { host! "test.gumroad.com" }

  def upload_zip(content = "PK-fake-zip", owner: user)
    key = "attachments/#{owner.external_id}/#{SecureRandom.hex}/original/game.zip"
    s3.put_object(bucket: S3_BUCKET, key:, body: content)
    "#{S3_BASE_URL}#{key}"
  end

  def deploy(url, product_id: product.external_id)
    post "/api/v2/products/#{product_id}/games/builds/deploy", params: { access_token: token.token, url: }
  end

  describe "POST deploy" do
    it "copies the upload to the product's games prefix as build 1 without making it live" do
      url = upload_zip("abc")
      deploy(url)

      build = response.parsed_body["game_build"]
      expect(response.parsed_body["success"]).to be true
      expect(build).to include("number" => 1, "status" => "uploaded", "byte_size" => 3)
      record = product.game_builds.sole
      expect(record.storage_key).to eq("games/#{product.id}/1/build.zip")
      expect(s3.get_object(bucket: S3_BUCKET, key: record.storage_key).body.read).to eq("abc")
      expect(product.product_files.alive).to be_empty
    end

    it "numbers builds sequentially" do
      deploy(upload_zip)
      deploy(upload_zip)
      expect(product.game_builds.pluck(:number)).to eq([1, 2])
    end

    it "is idempotent for a retried deploy of the same upload" do
      url = upload_zip
      deploy(url)
      deploy(url)
      expect(response.parsed_body["success"]).to be true
      expect(product.game_builds.count).to eq(1)
    end

    it "keeps the build immutable when the source upload is overwritten later" do
      url = upload_zip("one")
      deploy(url)
      s3.put_object(bucket: S3_BUCKET, key: url.delete_prefix(S3_BASE_URL), body: "two")
      expect(s3.get_object(bucket: S3_BUCKET, key: product.game_builds.sole.storage_key).body.read).to eq("one")
    end

    it "rejects a url outside the seller's own uploads" do
      deploy(upload_zip(owner: create(:user)))
      expect(response.parsed_body).to include("success" => false)
      expect(product.game_builds).to be_empty
    end

    it "rejects a url that is not a zip" do
      deploy("#{S3_BASE_URL}attachments/#{user.external_id}/x/original/game.html")
      expect(response.parsed_body["success"]).to be false
    end

    it "rejects path traversal" do
      deploy("#{S3_BASE_URL}attachments/#{user.external_id}/../#{create(:user).external_id}/a.zip")
      expect(response.parsed_body["success"]).to be false
    end

    it "reports an upload that was never completed" do
      deploy("#{S3_BASE_URL}attachments/#{user.external_id}/missing/original/game.zip")
      expect(response.parsed_body["success"]).to be false
      expect(response.parsed_body["message"]).to include("not found")
    end

    it "caps builds per product" do
      stub_const("GameBuild::MAX_BUILDS_PER_PRODUCT", 1)
      deploy(upload_zip)
      deploy(upload_zip)
      expect(response.parsed_body["success"]).to be false
      expect(product.game_builds.count).to eq(1)
    end

    it "does not deploy to another seller's product" do
      deploy(upload_zip, product_id: create(:product).external_id)
      expect(response.parsed_body["success"]).to be false
    end

    it "requires the edit_products scope" do
      read_token = create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "view_public")
      post "/api/v2/products/#{product.external_id}/games/builds/deploy", params: { access_token: read_token.token, url: upload_zip }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST promote" do
    it "makes the build live and attaches it as the product's download" do
      deploy(upload_zip)
      build = product.game_builds.sole

      post "/api/v2/products/#{product.external_id}/games/builds/#{build.external_id}/promote", params: { access_token: token.token }

      expect(response.parsed_body["game_build"]).to include("status" => "live")
      file = product.product_files.alive.sole
      expect(file.url).to eq("#{S3_BASE_URL}#{build.storage_key}")
      expect(build.reload.product_file).to eq(file)
    end

    it "supersedes the previous live build and swaps the download" do
      deploy(upload_zip)
      deploy(upload_zip)
      first, second = product.game_builds.to_a

      [first, second].each do |b|
        post "/api/v2/products/#{product.external_id}/games/builds/#{b.external_id}/promote", params: { access_token: token.token }
      end

      expect(first.reload.status).to eq("superseded")
      expect(second.reload.status).to eq("live")
      expect(product.product_files.alive.sole.url).to end_with("/2/build.zip")
    end

    it "can roll back to a superseded build" do
      deploy(upload_zip)
      deploy(upload_zip)
      first, second = product.game_builds.to_a
      [first, second, first].each do |b|
        post "/api/v2/products/#{product.external_id}/games/builds/#{b.external_id}/promote", params: { access_token: token.token }
      end
      expect(product.game_builds.live.pluck(:number)).to eq([1])
      expect(product.product_files.alive.sole.url).to end_with("/1/build.zip")
    end

    it "is a no-op for an already-live build" do
      deploy(upload_zip)
      build = product.game_builds.sole
      2.times { post "/api/v2/products/#{product.external_id}/games/builds/#{build.external_id}/promote", params: { access_token: token.token } }
      expect(product.product_files.alive.count).to eq(1)
    end
  end

  describe "GET index / show" do
    it "lists builds and shows one" do
      deploy(upload_zip)
      get "/api/v2/products/#{product.external_id}/games/builds", params: { access_token: token.token }
      expect(response.parsed_body["game_builds"].map { _1["number"] }).to eq([1])

      id = response.parsed_body["game_builds"].first["id"]
      get "/api/v2/products/#{product.external_id}/games/builds/#{id}", params: { access_token: token.token }
      expect(response.parsed_body["game_build"]["id"]).to eq(id)
    end

    it "does not expose another product's build" do
      other = create(:product, user:)
      deploy(upload_zip, product_id: other.external_id)
      id = other.game_builds.sole.external_id
      get "/api/v2/products/#{product.external_id}/games/builds/#{id}", params: { access_token: token.token }
      expect(response.parsed_body["success"]).to be false
    end
  end
end
