# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::ProductsController do
  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:user, email: "seller@example.com") }

  before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

  describe "GET index" do
    include_examples "admin api authorization required", :get, :index

    it "returns a bad request when neither email nor external_id is provided" do
      get :index

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or external_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :index, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "looks up the seller by external_id when provided" do
      product = create(:product, user: seller)

      get :index, params: { external_id: seller.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["products"].map { _1["id"] }).to eq([product.external_id])
    end

    it "returns not found when the external_id does not match any user" do
      get :index, params: { external_id: "nonexistent" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "prefers external_id over email when both are provided" do
      other_seller = create(:user, email: "other@example.com")
      external_match = create(:product, user: seller, name: "via external_id")
      create(:product, user: other_seller, name: "via email")

      get :index, params: { email: other_seller.email, external_id: seller.external_id }

      expect(response.parsed_body["products"].map { _1["name"] }).to eq([external_match.name])
    end

    it "returns products for a soft-deleted seller looked up by external_id" do
      product = create(:product, user: seller)
      seller.mark_deleted!

      get :index, params: { external_id: seller.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["products"].map { _1["id"] }).to eq([product.external_id])
    end

    it "returns an empty list with pagination metadata when the seller has no products" do
      get :index, params: { email: seller.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["products"]).to eq([])
      expect(response.parsed_body["pagination"]).to include("count" => 0, "page" => 1)
    end

    it "returns alive and soft-deleted products with their deletion state exposed" do
      alive_product = create(:product, user: seller, name: "Alive guide")
      deleted_product = create(:product, user: seller, name: "Old draft")
      deleted_product.mark_deleted!

      get :index, params: { email: seller.email }

      expect(response).to have_http_status(:ok)
      products = response.parsed_body["products"]
      expect(products.length).to eq(2)
      ids = products.map { _1["id"] }
      expect(ids).to contain_exactly(alive_product.external_id, deleted_product.external_id)

      alive_payload = products.find { _1["id"] == alive_product.external_id }
      expect(alive_payload["deleted_at"]).to be_nil
      expect(alive_payload["alive"]).to be(true)

      deleted_payload = products.find { _1["id"] == deleted_product.external_id }
      expect(deleted_payload["deleted_at"]).to be_present
      expect(deleted_payload["alive"]).to be(false)
    end

    it "orders alive products before deleted ones, then by created_at desc" do
      create(:product, user: seller, name: "Old alive", created_at: 3.days.ago)
      create(:product, user: seller, name: "New alive", created_at: 1.day.ago)
      deleted = create(:product, user: seller, name: "Deleted")
      deleted.mark_deleted!

      get :index, params: { email: seller.email }

      names = response.parsed_body["products"].map { _1["name"] }
      expect(names).to eq(["New alive", "Old alive", "Deleted"])
    end

    it "surfaces external-link files with their URL and a URL extension" do
      product = create(:product, user: seller)
      external = create(:external_link, link: product, display_name: "Telegram channel", url: "https://t.me/secret-channel")

      get :index, params: { email: seller.email }

      files = response.parsed_body["products"].first["files"]
      payload = files.find { _1["id"] == external.external_id }
      expect(payload).to include(
        "display_name" => "Telegram channel",
        "file_name" => "https://t.me/secret-channel",
        "extension" => "URL",
        "filegroup" => external.filegroup
      )
    end

    it "preloads product files instead of issuing one query per product" do
      3.times do
        product = create(:product, user: seller)
        create(:readable_document, link: product)
        create(:readable_document, link: product)
      end

      product_files_queries = []
      counter = lambda do |*, payload|
        sql = payload[:sql]
        next if sql.blank? || sql.start_with?("INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "SAVEPOINT", "RELEASE")
        product_files_queries << sql if sql.include?("`product_files`") && sql.include?("SELECT")
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :index, params: { email: seller.email }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["products"].length).to eq(3)
      expect(product_files_queries.length).to eq(1), "expected one product_files SELECT but got #{product_files_queries.length}:\n#{product_files_queries.join("\n")}"
      expect(product_files_queries.first).to include("IN (")
    end

    it "resolves taxonomy ancestry with a single batched query across distinct taxonomies" do
      root = Taxonomy.create!(slug: "root")
      branch_a = Taxonomy.create!(slug: "branch-a", parent: root)
      branch_b = Taxonomy.create!(slug: "branch-b", parent: root)
      branch_c = Taxonomy.create!(slug: "branch-c", parent: root)
      create(:product, user: seller, taxonomy: branch_a)
      create(:product, user: seller, taxonomy: branch_b)
      create(:product, user: seller, taxonomy: branch_c)

      hierarchy_queries = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s
        next if sql.start_with?("INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "SAVEPOINT", "RELEASE")
        hierarchy_queries << sql if sql.include?("taxonomy_hierarchies") && sql.start_with?("SELECT")
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :index, params: { email: seller.email }
      end

      expect(response).to have_http_status(:ok)
      paths = response.parsed_body["products"].map { _1["taxonomy"]["ancestry_path"] }
      expect(paths).to contain_exactly(["root", "branch-a"], ["root", "branch-b"], ["root", "branch-c"])
      expect(hierarchy_queries.length).to eq(1),
                                          "expected one batched taxonomy_hierarchies SELECT but got #{hierarchy_queries.length}:\n#{hierarchy_queries.join("\n")}"
    end

    it "exposes file metadata including soft-deleted files" do
      product = create(:product, user: seller)
      alive_file = create(:readable_document, link: product, display_name: "Big guide", size: 1_048_576)
      deleted_file = create(:readable_document, link: product, display_name: "Removed extra", size: 256)
      deleted_file.mark_deleted!

      get :index, params: { email: seller.email }

      files = response.parsed_body["products"].first["files"]
      expect(files.length).to eq(2)

      alive_payload = files.find { _1["id"] == alive_file.external_id }
      expect(alive_payload).to include(
        "display_name" => "Big guide",
        "extension" => "PDF",
        "filegroup" => "document",
        "file_size" => 1_048_576,
        "deleted_at" => nil
      )
      expect(alive_payload["file_name"]).to end_with(".pdf")

      deleted_payload = files.find { _1["id"] == deleted_file.external_id }
      expect(deleted_payload["file_size"]).to eq(256)
      expect(deleted_payload["deleted_at"]).to be_present
    end

    it "returns the cover image url when one is present" do
      product = create(:product, :with_youtube_preview, user: seller)

      get :index, params: { email: seller.email }

      payload = response.parsed_body["products"].first
      expect(payload["preview_url"]).to eq(product.preview_url)
      expect(payload["preview_url"]).to be_present
    end

    it "paginates with the default per_page" do
      stub_const("Api::Internal::Admin::ProductsController::DEFAULT_PER_PAGE", 2)
      create_list(:product, 3, user: seller)

      get :index, params: { email: seller.email }
      expect(response.parsed_body["products"].length).to eq(2)
      expect(response.parsed_body["pagination"]).to include("count" => 3, "page" => 1, "next" => 2)

      get :index, params: { email: seller.email, page: 2 }
      expect(response.parsed_body["products"].length).to eq(1)
      expect(response.parsed_body["pagination"]).to include("page" => 2, "next" => nil)
    end

    it "treats non-positive or non-numeric page as page 1 (rather than raising 500)" do
      product = create(:product, user: seller)

      ["0", "-5", "abc", ""].each do |bad_page|
        get :index, params: { email: seller.email, page: bad_page }

        expect(response).to have_http_status(:ok), "page=#{bad_page.inspect} returned #{response.status}"
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["pagination"]["page"]).to eq(1)
        expect(response.parsed_body["products"].map { _1["id"] }).to eq([product.external_id])
      end
    end

    it "returns an empty page in the JSON envelope when page is past the end (rather than raising 500)" do
      create(:product, user: seller)

      get :index, params: { email: seller.email, page: 99 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["products"]).to eq([])
      expect(response.parsed_body["pagination"]["next"]).to be_nil
    end

    it "orders product files with NULL position first to match MySQL ORDER BY ASC" do
      product = create(:product, user: seller)
      first = create(:readable_document, link: product, display_name: "First (null pos)")
      second = create(:readable_document, link: product, display_name: "Second", position: 0)
      third = create(:readable_document, link: product, display_name: "Third", position: 1)
      first.update_column(:position, nil)

      get :index, params: { email: seller.email }

      ids = response.parsed_body["products"].first["files"].map { _1["id"] }
      expect(ids).to eq([first.external_id, second.external_id, third.external_id])
    end

    it "honors per_page and caps it at the maximum" do
      create_list(:product, 5, user: seller)

      get :index, params: { email: seller.email, per_page: 2 }
      expect(response.parsed_body["products"].length).to eq(2)

      get :index, params: { email: seller.email, per_page: 10_000 }
      expect(response.parsed_body["products"].length).to eq(5)
    end

    it "scopes results to the requested seller and excludes other sellers' products" do
      other_seller = create(:user, email: "other@example.com")
      mine = create(:product, user: seller)
      create(:product, user: other_seller)

      get :index, params: { email: seller.email }

      ids = response.parsed_body["products"].map { _1["id"] }
      expect(ids).to eq([mine.external_id])
    end
  end

  describe "GET show" do
    include_examples "admin api authorization required", :get, :show, { id: "fake" }

    it "returns not found when no product matches" do
      get :show, params: { id: "fake" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Product not found" }.as_json)
    end

    it "returns the full product payload with file metadata" do
      product = create(:product, user: seller, name: "Edgar Gumstein anthology", description: "The full collection.", price_cents: 20_000)
      file = create(:readable_document, link: product, display_name: "Anthology", size: 5_242_880)

      get :show, params: { id: product.external_id }

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body["product"]
      expect(payload).to include(
        "id" => product.external_id,
        "name" => "Edgar Gumstein anthology",
        "description" => "The full collection.",
        "price_cents" => 20_000,
        "permalink" => product.unique_permalink,
        "alive" => true,
        "deleted_at" => nil
      )
      expect(payload["files"].length).to eq(1)
      expect(payload["files"].first).to include(
        "id" => file.external_id,
        "file_size" => 5_242_880,
        "extension" => "PDF",
        "filegroup" => "document",
        "display_name" => "Anthology"
      )
    end

    it "returns a soft-deleted product so admins can inspect tombstones" do
      product = create(:product, user: seller)
      product.mark_deleted!

      get :show, params: { id: product.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["product"]["deleted_at"]).to be_present
      expect(response.parsed_body["product"]["alive"]).to be(false)
    end

    it "includes soft-deleted files with deleted_at populated" do
      product = create(:product, user: seller)
      file = create(:readable_document, link: product, display_name: "Removed", size: 100)
      file.mark_deleted!

      get :show, params: { id: product.external_id }

      payload = response.parsed_body["product"]["files"].first
      expect(payload["id"]).to eq(file.external_id)
      expect(payload["deleted_at"]).to be_present
    end

    it "exposes banned_at and purchase_disabled_at when set, nil when not" do
      banned = create(:product, user: seller, banned_at: 1.day.ago)
      banned.update_column(:purchase_disabled_at, 2.days.ago)
      clean = create(:product, user: seller)

      get :show, params: { id: banned.external_id }
      expect(response.parsed_body["product"]).to include(
        "banned_at" => banned.banned_at.iso8601,
        "purchase_disabled_at" => banned.purchase_disabled_at.iso8601,
        "alive" => false
      )

      get :show, params: { id: clean.external_id }
      expect(response.parsed_body["product"]).to include(
        "banned_at" => nil,
        "purchase_disabled_at" => nil
      )
    end

    it "returns the bad-card counter value as stored on the product" do
      product = create(:product, user: seller)
      product.update_column(:bad_card_counter, 7)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["bad_card_counter"]).to eq(7)
    end

    it "returns the taxonomy slug and ancestry path when assigned" do
      root = Taxonomy.create!(slug: "physical-goods")
      child = Taxonomy.create!(slug: "books", parent: root)
      product = create(:product, user: seller, taxonomy: child)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["taxonomy"]).to eq(
        "id" => child.id.to_s,
        "slug" => "books",
        "ancestry_path" => ["physical-goods", "books"]
      )
    end

    it "returns null taxonomy when none is assigned" do
      product = create(:product, user: seller, taxonomy: nil)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["taxonomy"]).to be_nil
    end

    it "lists attached direct affiliates with the fallback basis points from the parent affiliate" do
      product = create(:product, user: seller, name: "Direct affiliate product")
      direct_user = create(:user, email: "direct@example.com")
      direct = create(:direct_affiliate, seller:, affiliate_user: direct_user, affiliate_basis_points: 1500, products: [product])
      ProductAffiliate.find_by!(affiliate: direct, product:).update!(affiliate_basis_points: nil, destination_url: "https://example.com/d")

      get :show, params: { id: product.external_id }

      payload = response.parsed_body["product"]["affiliates"]
      expect(payload.length).to eq(1)
      expect(payload.first).to include(
        "id" => direct.external_id,
        "type" => "DirectAffiliate",
        "basis_points" => 1500,
        "destination_url" => "https://example.com/d",
        "alive" => true,
        "deleted_at" => nil
      )
      expect(payload.first["affiliate_user"]).to eq(
        "id" => direct_user.external_id,
        "email" => "direct@example.com"
      )
    end

    it "surfaces soft-deleted affiliates with their lifecycle state so reviewers see recently removed ones" do
      product = create(:product, user: seller)
      direct_user = create(:user)
      deleted_at = 1.day.ago
      direct = create(:direct_affiliate, seller:, affiliate_user: direct_user, products: [product])
      direct.update!(deleted_at:)

      get :show, params: { id: product.external_id }

      payload = response.parsed_body["product"]["affiliates"].first
      expect(payload).to include(
        "id" => direct.external_id,
        "alive" => false,
        "deleted_at" => deleted_at.as_json
      )
    end

    it "lists collaborators with per-product basis-point overrides" do
      product = create(:product, user: seller, name: "Collab product")
      collab_user = create(:user, email: "collab@example.com")
      collab = create(:collaborator, seller:, affiliate_user: collab_user, apply_to_all_products: false, affiliate_basis_points: 2000)
      create(:product_affiliate, affiliate: collab, product:, affiliate_basis_points: 2500)

      get :show, params: { id: product.external_id }

      payload = response.parsed_body["product"]["affiliates"]
      expect(payload.length).to eq(1)
      expect(payload.first).to include(
        "id" => collab.external_id,
        "type" => "Collaborator",
        "basis_points" => 2500
      )
    end

    it "excludes global affiliates from the attached affiliates list" do
      product = create(:product, user: seller)
      direct_user = create(:user)
      direct = create(:direct_affiliate, seller:, affiliate_user: direct_user, products: [product])
      global = create(:user).global_affiliate
      create(:product_affiliate, affiliate: global, product:)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["affiliates"].map { _1["id"] }).to eq([direct.external_id])
    end

    it "returns an empty affiliates list when none are attached" do
      product = create(:product, user: seller)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["affiliates"]).to eq([])
    end

    it "computes recent_chargeback_rate over a 90 day window from successful sales" do
      create(:merchant_account, user: nil)
      product = create(:product, user: seller)
      4.times { create(:purchase, link: product, seller:, created_at: 10.days.ago) }
      chargedback = create(:purchase, link: product, seller:, created_at: 5.days.ago)
      chargedback.update_column(:chargeback_date, 4.days.ago)
      stale_chargeback = create(:purchase, link: product, seller:, created_at: 100.days.ago)
      stale_chargeback.update_column(:chargeback_date, 95.days.ago)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["recent_chargeback_rate"]).to eq(
        "window_days" => 90,
        "successful_count" => 5,
        "chargedback_count" => 1,
        "rate" => 0.2
      )
    end

    it "excludes reversed chargebacks from recent_chargeback_rate, matching the rest of the fraud-signal stack" do
      create(:merchant_account, user: nil)
      product = create(:product, user: seller)
      4.times { create(:purchase, link: product, seller:, created_at: 10.days.ago) }
      lost = create(:purchase, link: product, seller:, created_at: 5.days.ago)
      lost.update_columns(chargeback_date: 4.days.ago)
      reversed = create(:purchase, link: product, seller:, created_at: 6.days.ago)
      reversed.update_columns(chargeback_date: 5.days.ago)
      reversed.update!(chargeback_reversed: true)

      get :show, params: { id: product.external_id }

      payload = response.parsed_body["product"]["recent_chargeback_rate"]
      expect(payload["successful_count"]).to eq(6)
      expect(payload["chargedback_count"]).to eq(1)
      expect(payload["rate"]).to eq((1.0 / 6).round(4))
    end

    it "excludes bundle sub-purchases from both successful_count and chargedback_count" do
      create(:merchant_account, user: nil)
      product = create(:product, user: seller)
      3.times { create(:purchase, link: product, seller:, created_at: 10.days.ago) }
      bundle_sub = create(:purchase, link: product, seller:, created_at: 8.days.ago, price_cents: 0)
      bundle_sub.update!(is_bundle_product_purchase: true)

      get :show, params: { id: product.external_id }

      payload = response.parsed_body["product"]["recent_chargeback_rate"]
      expect(payload["successful_count"]).to eq(3)
      expect(payload["chargedback_count"]).to eq(0)
      expect(payload["rate"]).to be_nil.or eq(0.0)
    end

    it "returns a recent_chargeback_rate with nil rate when there are no recent successful purchases" do
      product = create(:product, user: seller)

      get :show, params: { id: product.external_id }

      expect(response.parsed_body["product"]["recent_chargeback_rate"]).to eq(
        "window_days" => 90,
        "successful_count" => 0,
        "chargedback_count" => 0,
        "rate" => nil
      )
    end

    it "omits recent_chargeback_rate from index rows to keep the listing cheap" do
      create(:merchant_account, user: nil)
      product = create(:product, user: seller)
      create(:purchase, link: product, seller:)

      get :index, params: { external_id: seller.external_id }

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["products"].find { _1["id"] == product.external_id }
      expect(row).not_to have_key("recent_chargeback_rate")
    end
  end
end
