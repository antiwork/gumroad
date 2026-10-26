# frozen_string_literal: true

require "spec_helper"

describe "Game builds API" do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "edit_products") }
  let(:s3) { Aws::S3::Client.new }

  before { host! "test.gumroad.com" }

  def upload_zip(content = "PK-fake-zip", owner: user, filename: "game.zip")
    key = "attachments/#{owner.external_id}/#{SecureRandom.hex}/original/#{filename}"
    s3.put_object(bucket: S3_BUCKET, key:, body: content)
    "#{S3_BASE_URL}#{key}"
  end

  def deploy(url, product_id: product.external_id)
    post "/api/v2/products/#{product_id}/games/builds/deploy", params: { access_token: token.token, url: }
  end

  def promote(build)
    post "/api/v2/products/#{product.external_id}/games/builds/#{build.public_id}/promote", params: { access_token: token.token }
  end

  def live_download_bytes
    s3.get_object(bucket: S3_BUCKET, key: product.product_files.alive.sole.s3_key).body.read
  end

  # File ids the buyer's download page lists, after checking the download endpoint serves each one.
  def buyer_file_ids(purchase)
    redirect_token = purchase.url_redirect.token
    get "/d/#{redirect_token}", headers: { "X-Inertia" => "true" }
    expect(response).to have_http_status(:ok)
    ids = response.parsed_body.dig("props", "content", "content_items").map { _1["id"] }
    ids.each do |id|
      get url_redirect_download_product_files_path(redirect_token, product_file_ids: [id], format: :json)
      expect(response).to have_http_status(:ok)
    end
    ids
  end

  describe "POST deploy" do
    it "copies the upload to the product's games prefix as build 1 without making it live" do
      url = upload_zip("abc")
      deploy(url)

      build = response.parsed_body["game_build"]
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be true
      expect(build).to include("number" => 1, "status" => "uploaded", "byte_size" => 3)
      record = product.game_builds.sole
      expect(record.storage_key).to eq("games/#{product.id}/1/build.zip")
      expect(s3.get_object(bucket: S3_BUCKET, key: record.storage_key).body.read).to eq("abc")
      expect(product.product_files.alive).to be_empty
    end

    it "copies an upload whose filename needs escaping in the copy source" do
      deploy(upload_zip("abc", filename: "Game #2.zip"))
      expect(response.parsed_body["success"]).to be true
      expect(s3.get_object(bucket: S3_BUCKET, key: product.game_builds.sole.storage_key).body.read).to eq("abc")
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

    it "still returns the build when a retry finds the source upload gone" do
      url = upload_zip
      deploy(url)
      s3.delete_object(bucket: S3_BUCKET, key: url.delete_prefix(S3_BASE_URL))
      deploy(url)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("success" => true)
      expect(response.parsed_body["game_build"]["number"]).to eq(1)
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

      post "/api/v2/products/#{product.external_id}/games/builds/#{build.public_id}/promote", params: { access_token: token.token }

      expect(response).to have_http_status(:ok)
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
        post "/api/v2/products/#{product.external_id}/games/builds/#{b.public_id}/promote", params: { access_token: token.token }
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
        post "/api/v2/products/#{product.external_id}/games/builds/#{b.public_id}/promote", params: { access_token: token.token }
      end
      expect(product.game_builds.live.pluck(:number)).to eq([1])
      expect(product.product_files.alive.sole.url).to end_with("/1/build.zip")
    end

    it "embeds the live zip in the product's content page and swaps it on the next promote" do
      rich = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hi" }] }])
      deploy(upload_zip)
      deploy(upload_zip)
      first, second = product.game_builds.to_a

      post "/api/v2/products/#{product.external_id}/games/builds/#{first.public_id}/promote", params: { access_token: token.token }
      embeds = -> { rich.reload.description.select { _1["type"] == "fileEmbed" }.map { _1.dig("attrs", "id") } }
      expect(embeds.call).to eq([first.reload.product_file.external_id])

      post "/api/v2/products/#{product.external_id}/games/builds/#{second.public_id}/promote", params: { access_token: token.token }
      expect(embeds.call).to eq([second.reload.product_file.external_id])
      expect(rich.reload.description.first["type"]).to eq("paragraph")
    end

    context "when variants have their own content" do
      let(:category) { create(:variant_category, link: product, title: "Versions") }
      let!(:variants) { [create(:variant, variant_category: category, name: "A"), create(:variant, variant_category: category, name: "B")] }
      let(:buyers) { variants.map { create(:purchase, link: product, variant_attributes: [_1], ip_address: "127.0.0.1").tap(&:create_url_redirect!) } }

      before { product.update!(has_same_rich_content_for_all_variants: false) }

      it "gives each variant's buyers the live zip from their first page and swaps it on the next promote" do
        pages = variants.map { create(:rich_content, entity: _1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hi" }] }]) }
        deploy(upload_zip)
        deploy(upload_zip)
        first, second = product.game_builds.to_a

        post "/api/v2/products/#{product.external_id}/games/builds/#{first.public_id}/promote", params: { access_token: token.token }
        expect(response).to have_http_status(:ok)
        first_file_id = first.reload.product_file.external_id
        pages.each { |page| expect(page.reload.description.map { _1.dig("attrs", "id") }).to include(first_file_id) }
        buyers.each { expect(buyer_file_ids(_1)).to eq([first_file_id]) }

        post "/api/v2/products/#{product.external_id}/games/builds/#{second.public_id}/promote", params: { access_token: token.token }
        buyers.each { expect(buyer_file_ids(_1)).to eq([second.reload.product_file.external_id]) }
      end

      it "gives buyers from before the versions existed the live zip when the product's own pages still embed files" do
        manual = product.product_files.create!(url: upload_zip("manual", filename: "manual.zip"))
        page = create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => manual.external_id, "uid" => SecureRandom.uuid } }])
        early_buyer = create(:purchase, link: product, ip_address: "127.0.0.1").tap(&:create_url_redirect!)
        deploy(upload_zip)
        build = product.game_builds.sole

        promote(build)

        expect(buyer_file_ids(early_buyer)).to eq([manual.external_id, build.reload.product_file.external_id])
        expect(page.reload.description.count { _1["type"] == "fileEmbed" }).to eq(2)
      end

      it "gives a version added after the promote the live zip when the live build is promoted again" do
        pages = variants.map { create(:rich_content, entity: _1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hi" }] }]) }
        deploy(upload_zip)
        build = product.game_builds.sole
        promote(build)
        file_id = build.reload.product_file.external_id
        post "/api/v2/products/#{product.external_id}/variant_categories/#{category.external_id}/variants", params: { name: "Deluxe" }, headers: { "Authorization" => "Bearer #{token.token}" }, as: :json
        deluxe_buyer = create(:purchase, link: product, variant_attributes: [category.variants.find_by!(name: "Deluxe")], ip_address: "127.0.0.1").tap(&:create_url_redirect!)
        expect(buyer_file_ids(deluxe_buyer)).to eq([])

        promote(build)

        expect(build.reload.product_file.external_id).to eq(file_id)
        expect(buyer_file_ids(deluxe_buyer)).to eq([file_id])
        buyers.each { expect(buyer_file_ids(_1)).to eq([file_id]) }
        pages.each { |page| expect(page.reload.description.count { _1["type"] == "fileEmbed" }).to eq(1) }
      end

      it "gives buyers of a variant without content pages the live zip, also after the seller saves the versions" do
        deploy(upload_zip)
        build = product.game_builds.sole

        post "/api/v2/products/#{product.external_id}/games/builds/#{build.public_id}/promote", params: { access_token: token.token }

        expect(response).to have_http_status(:ok)
        buyers.each { expect(buyer_file_ids(_1)).to eq([build.reload.product_file.external_id]) }

        # The editor resubmits each version with the pages it shows.
        options = variants.map do |variant|
          pages = variant.alive_rich_contents.map { { id: _1.external_id, title: _1.title, description: _1.description } }
          { id: variant.external_id, name: variant.name, rich_content: pages }
        end
        Product::VariantsUpdaterService.new(product: product.reload, variants_params: [{ id: category.external_id, name: category.title, options: }]).perform
        buyers.each { expect(buyer_file_ids(_1)).to eq([build.reload.product_file.external_id]) }
      end
    end

    it "keeps a superseded build's object through the deleted-files cleanup so it can be rolled back to" do
      deploy(upload_zip("one"))
      deploy(upload_zip("two"))
      first, second = product.game_builds.to_a
      [first, second].each do |b|
        post "/api/v2/products/#{product.external_id}/games/builds/#{b.public_id}/promote", params: { access_token: token.token }
      end
      ProductFile.where(id: first.product_file_id).update_all(deleted_at: 2.days.ago)

      RemoveDeletedFilesFromS3Job.new.perform

      expect { s3.head_object(bucket: S3_BUCKET, key: first.storage_key) }.not_to raise_error
      post "/api/v2/products/#{product.external_id}/games/builds/#{first.public_id}/promote", params: { access_token: token.token }
      expect(product.product_files.alive.sole.url).to end_with("/1/build.zip")
    end

    it "lets a deleted unsold product's build downloads be removed from S3" do
      deploy(upload_zip)
      deploy(upload_zip)
      first, second = product.game_builds.to_a
      [first, second].each { promote(_1) }
      product.delete!
      DeleteProductFilesWorker.new.perform(product.id)
      product.product_files.update_all(deleted_at: 2.days.ago)

      RemoveDeletedFilesFromS3Job.new.perform

      [first, second].each do |build|
        expect { s3.head_object(bucket: S3_BUCKET, key: build.storage_key) }.to raise_error(Aws::S3::Errors::NotFound)
      end
    end

    it "is a no-op for an already-live build" do
      deploy(upload_zip)
      build = product.game_builds.sole
      2.times { post "/api/v2/products/#{product.external_id}/games/builds/#{build.public_id}/promote", params: { access_token: token.token } }
      expect(product.product_files.alive.count).to eq(1)
    end

    context "when the seller deleted the live build's download" do
      def delete_files_via_api
        put "/api/v2/products/#{product.external_id}", params: { files: [] }, headers: { "Authorization" => "Bearer #{token.token}" }, as: :json
        expect(response.parsed_body["success"]).to be true
      end

      it "restores the product's download when the live build is promoted again" do
        buyer = create(:purchase, link: product, ip_address: "127.0.0.1").tap(&:create_url_redirect!)
        deploy(upload_zip("one"))
        build = product.game_builds.sole
        promote(build)
        delete_files_via_api
        expect(buyer_file_ids(buyer)).to eq([])

        promote(build)

        expect(response).to have_http_status(:ok)
        expect(product.game_builds.live.pluck(:number)).to eq([1])
        expect(buyer_file_ids(buyer)).to eq([build.reload.product_file.external_id])
        product.product_files.deleted.update_all(deleted_at: 2.days.ago)
        RemoveDeletedFilesFromS3Job.new.perform
        expect(live_download_bytes).to eq("one")
      end

      it "replaces an embed the deleted download left on the content page instead of adding a second one" do
        page = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hi" }] }])
        deploy(upload_zip)
        build = product.game_builds.sole
        promote(build)
        deleted_file = build.reload.product_file
        deleted_file.mark_deleted!

        promote(build)

        expect(build.reload.product_file).not_to eq(deleted_file)
        expect(page.reload.description.filter_map { _1.dig("attrs", "id") if _1["type"] == "fileEmbed" }).to eq([build.product_file.external_id])
      end

      it "restores each variant's download without leaving the deleted file's embed or duplicating the new one" do
        category = create(:variant_category, link: product, title: "Versions")
        variants = [create(:variant, variant_category: category, name: "A"), create(:variant, variant_category: category, name: "B")]
        product.update!(has_same_rich_content_for_all_variants: false)
        pages = variants.map { create(:rich_content, entity: _1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hi" }] }]) }
        buyers = variants.map { create(:purchase, link: product, variant_attributes: [_1], ip_address: "127.0.0.1").tap(&:create_url_redirect!) }
        deploy(upload_zip)
        build = product.game_builds.sole
        promote(build)
        deleted_file_id = build.reload.product_file.external_id
        # The API refuses to delete an embedded file, so the seller unembeds it from each version first.
        variants.zip(pages).each do |variant, page|
          content = { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Hi" }] }] }
          put "/api/v2/products/#{product.external_id}/variant_categories/#{category.external_id}/variants/#{variant.external_id}",
              params: { rich_content: [{ id: page.external_id, title: nil, description: content }] }, headers: { "Authorization" => "Bearer #{token.token}" }, as: :json
          expect(response.parsed_body["success"]).to be true
        end
        delete_files_via_api
        buyers.each { expect(buyer_file_ids(_1)).to eq([]) }

        promote(build)

        new_file_id = build.reload.product_file.external_id
        expect(new_file_id).not_to eq(deleted_file_id)
        buyers.each { expect(buyer_file_ids(_1)).to eq([new_file_id]) }
        pages.each do |page|
          expect(page.reload.description.filter_map { _1.dig("attrs", "id") if _1["type"] == "fileEmbed" }).to eq([new_file_id])
          expect(page.description.first["type"]).to eq("paragraph")
        end
      end
    end
  end

  describe "GET index / show" do
    it "lists builds and shows one" do
      deploy(upload_zip)
      get "/api/v2/products/#{product.external_id}/games/builds", params: { access_token: token.token }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["game_builds"].map { _1["number"] }).to eq([1])

      id = response.parsed_body["game_builds"].first["id"]
      get "/api/v2/products/#{product.external_id}/games/builds/#{id}", params: { access_token: token.token }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["game_build"]["id"]).to eq(id)
    end

    it "does not expose another product's build" do
      other = create(:product, user:)
      deploy(upload_zip, product_id: other.external_id)
      id = other.game_builds.sole.public_id
      get "/api/v2/products/#{product.external_id}/games/builds/#{id}", params: { access_token: token.token }
      expect(response.parsed_body["success"]).to be false
    end
  end
end
