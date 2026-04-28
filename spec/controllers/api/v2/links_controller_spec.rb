# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
      @product1 = create(:product, user: @user, description: "des1", created_at: Time.current)
      @product2 = create(:product, user: @user, description: "des2", created_at: Time.current + 3600, purchase_disabled_at: Time.current + 3600)
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          products: [@product2, @product1]
        }.as_json(api_scopes: ["view_public"], slim: true))
      end

      it "omits detail-only fields from the slim response" do
        versioned_product = create(:product_with_digital_versions, user: @user, created_at: Time.current + 7200)
        create(:product_file, link: versioned_product, url: "#{S3_BASE_URL}specs/test.pdf")
        create(:rich_content, entity: versioned_product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "hello" }] }])
        create(:rich_content, entity: versioned_product.alive_variants.first, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "variant" }] }])

        get @action, params: @params

        product = response.parsed_body["products"].find { |item| item["id"] == versioned_product.external_id }
        expect(product).to be_present
        expect(product).not_to have_key("rich_content")
        expect(product).not_to have_key("has_same_rich_content_for_all_variants")
        expect(product).not_to have_key("files")
        expect(product["variants"].first["options"].first).not_to have_key("rich_content")
      end

      it "paginates results and returns page_key when there are more products" do
        (1..11).map { |i| create(:product, user: @user, created_at: Time.current + i.hours) }

        get @action, params: @params

        body = response.parsed_body
        expect(body["success"]).to be true
        expect(body["products"].size).to eq(10)
        expect(body["next_page_key"]).to be_present
        expect(body["next_page_url"]).to be_present
      end

      it "returns the next page of results when page_key is provided" do
        (1..12).map { |i| create(:product, user: @user, created_at: Time.current + i.hours) }

        get @action, params: @params
        first_page = response.parsed_body
        expect(first_page["products"].size).to eq(10)
        page_key = first_page["next_page_key"]

        get @action, params: @params.merge(page_key: page_key)
        second_page = response.parsed_body
        expect(second_page["success"]).to be true
        # 12 + 2 original products = 14 total; first page = 10, second page = 4
        expect(second_page["products"].size).to eq(4)
        expect(second_page).not_to have_key("next_page_key")

        first_page_ids = first_page["products"].map { |p| p["id"] }
        second_page_ids = second_page["products"].map { |p| p["id"] }
        expect(first_page_ids & second_page_ids).to be_empty
      end

      it "does not include pagination keys when all results fit on one page" do
        get @action, params: @params

        body = response.parsed_body
        expect(body["success"]).to be true
        expect(body["products"].size).to eq(2)
        expect(body).not_to have_key("next_page_key")
        expect(body).not_to have_key("next_page_url")
      end

      it "returns an error for an invalid page_key" do
        get @action, params: @params.merge(page_key: "invalid")

        expect(response).to have_http_status(:bad_request)
        body = response.parsed_body
        expect(body["error"]).to eq("Invalid page_key.")
      end
    end

    describe "when logged in with sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        @product1.reload
        @product2.reload
        expect(response.parsed_body).to eq({ success: true, products: [@product2, @product1] }.as_json(api_scopes: ["view_sales"], slim: true))
      end
    end

    it "grants access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get @action, params: { access_token: token.token }
      expect(response).to be_successful
      expect(response.parsed_body["products"]).to be_present
    end

    describe "query count" do
      def count_sql_queries(&block)
        count = 0
        ActiveSupport::Notifications.subscribed(->(*) { count += 1 }, "sql.active_record", &block)
        count
      end

      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(format: :json, access_token: @token.token)
      end

      it "batch loads file_attachment and file_blob for covers (not one query per record)" do
        3.times { create(:asset_preview, link: @product1) }
        3.times { create(:asset_preview, link: @product2) }

        cover_attachment_queries = []
        cover_blob_queries = []
        counter = lambda { |*, payload|
          sql = payload[:sql]
          next if sql.nil? || sql.include?("VariantRecord") || sql.include?("INSERT")
          cover_attachment_queries << sql if sql.include?("active_storage_attachments") && sql.include?("AssetPreview")
          cover_blob_queries << sql if sql.include?("active_storage_blobs") && !sql.include?("INNER JOIN")
        }

        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          get @action, params: @params
        end

        expect(cover_attachment_queries.count).to eq(1)
        expect(cover_attachment_queries.first).to include("IN (")
        expect(cover_blob_queries.count).to eq(1)
        expect(cover_blob_queries.first).to include("IN (")
      end
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = { name: "Some product", price: 200 }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
        Taxonomy.find_or_create_by!(slug: "other")
      end

      it "creates a digital product with minimal params" do
        expect do
          post @action, params: @params
        end.to change { @user.links.count }.by(1)

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to be true

        product = @user.links.last
        expect(product.name).to eq("Some product")
        expect(product.price_cents).to eq(200)
        expect(product.native_type).to eq("digital")
        expect(product.draft).to be true
        expect(product.purchase_disabled_at).to be_present
        expect(product.display_product_reviews).to be true
      end

      it "marks products created from the CLI and marks the user without dropping other flags" do
        request.user_agent = "gumroad-cli/1.0"
        stale_user = @user.reload
        other_flag_mask = User.flag_mapping["flags"][:disable_paypal_sales]
        allow(controller).to receive(:current_resource_owner).and_return(stale_user)

        allow(controller).to receive(:mark_cli_user).and_wrap_original do |original, *args|
          User.where(id: @user.id).update_all(["flags = flags | ?", other_flag_mask])
          original.call(*args)
        end

        post @action, params: @params

        product = @user.links.last
        @user.reload
        expect(product.created_via_cli?).to be true
        expect(@user.has_used_cli?).to be true
        expect(@user.disable_paypal_sales?).to be true
      end

      it "creates a product with all optional params" do
        post @action, params: @params.merge(
          description: "<p>A great product</p>",
          native_type: "course",
          price_currency_type: "eur",
          customizable_price: true,
          suggested_price_cents: 500,
          custom_permalink: "my-course",
          custom_summary: "A short summary",
          max_purchase_count: 50,
          tags: ["ruby", "rails"]
        )

        expect(response).to be_successful
        product = @user.links.last
        expect(product.description).to eq("<p>A great product</p>")
        expect(product.native_type).to eq("course")
        expect(product.price_currency_type).to eq("eur")
        expect(product.customizable_price).to be true
        expect(product.suggested_price_cents).to eq(500)
        expect(product.custom_permalink).to eq("my-course")
        expect(product.json_data["custom_summary"]).to eq("A short summary")
        expect(product.max_purchase_count).to eq(50)
        expect(product.tags.pluck(:name)).to match_array(["ruby", "rails"])
      end

      it "creates a membership and derives is_recurring_billing from native_type" do
        post @action, params: @params.merge(
          native_type: "membership",
          subscription_duration: "monthly"
        )

        expect(response).to be_successful
        product = @user.links.last
        expect(product.native_type).to eq("membership")
        expect(product.is_recurring_billing).to be true
        expect(product.is_tiered_membership).to be true
        expect(product.should_show_all_posts).to be true
        expect(product.subscription_duration).to eq("monthly")
      end

      it "creates a bundle product" do
        post @action, params: @params.merge(native_type: "bundle")

        expect(response).to be_successful
        product = @user.links.last
        expect(product.native_type).to eq("bundle")
        expect(product.is_bundle).to be true
      end

      it "creates a coffee product with donate prompt" do
        @user.update!(created_at: 2.months.ago)

        post @action, params: @params.merge(native_type: "coffee")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
        product = @user.links.last
        expect(product.native_type).to eq("coffee")
        expect(product.json_data["custom_button_text_option"]).to eq("donate_prompt")
      end

      it "creates a call product" do
        @user.update!(created_at: 2.months.ago)

        post @action, params: @params.merge(native_type: "call")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
        product = @user.links.last
        expect(product.native_type).to eq("call")
        expect(product.call_limitation_info).to be_present
      end

      it "rejects service types when seller is not eligible" do
        @user.update!(created_at: Time.current)

        post @action, params: @params.merge(native_type: "call")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
      end

      it "rejects unsupported types" do
        %w[podcast newsletter audiobook physical].each do |unsupported_type|
          post @action, params: @params.merge(native_type: unsupported_type)

          expect(response).to be_successful
          expect(response.parsed_body["success"]).to be false
          expect(response.parsed_body["message"]).to include("not supported for creation")
        end
      end

      it "rejects commission when commissions feature flag is off" do
        post @action, params: @params.merge(native_type: "commission")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("do not have access")
      end

      it "rejects subscription_duration for non-membership products" do
        post @action, params: @params.merge(subscription_duration: "monthly")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("only valid for membership")
      end

      it "respects daily creation limit", :enforce_product_creation_limit do
        @user.links.delete_all
        limit = @user.compliant? ? 100 : 10
        create_list(:product, limit, user: @user)

        post @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("products per day")
      end

      it "rejects invalid subscription_duration" do
        post @action, params: @params.merge(native_type: "membership", subscription_duration: "weekly")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("Invalid subscription duration")
      end

      it "rejects invalid price_currency_type" do
        post @action, params: @params.merge(price_currency_type: "xyz")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("not a supported currency")
      end

      it "returns validation errors in standard format" do
        post @action, params: @params.merge(name: "")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to be_present
      end

      it "starts as a draft with purchase_disabled_at set" do
        post @action, params: @params

        product = @user.links.last
        expect(product.draft).to be true
        expect(product.purchase_disabled_at).to be_present
      end

      it "saves tags correctly" do
        post @action, params: @params.merge(tags: ["valid-tag"])

        expect(response).to be_successful
        expect(@user.links.last.tags.pluck(:name)).to eq(["valid-tag"])
      end

      it "rejects non-array tags" do
        post @action, params: @params.merge(tags: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("tags must be an array")
      end

      it "rejects tags with non-string elements" do
        post @action, params: @params.merge(tags: ["valid", { nested: "hash" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("tags must be an array of strings")
      end

      it "rejects non-array rich_content" do
        post @action, params: @params.merge(rich_content: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array")
      end

      it "rejects rich_content pages with non-object description" do
        post @action, params: @params.merge(rich_content: [{ description: "oops" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("description must be a JSON object or array")
      end

      it "rejects rich_content with non-array wrapper content" do
        post @action, params: @params.merge(rich_content: [{ description: { type: "doc", content: "oops" } }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content must be an array")
      end

      it "rejects rich_content with hash wrapper content" do
        post @action, params: @params.merge(rich_content: [{ description: { type: "doc", content: { foo: "bar" } } }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content must be an array")
      end

      it "rejects rich_content with non-object content nodes in wrapper" do
        post @action, params: @params.merge(rich_content: [{ description: { type: "doc", content: [1, "text"] } }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content node must be a JSON object")
      end

      it "rejects rich_content with non-object content nodes in raw array" do
        post @action, params: @params.merge(rich_content: [{ description: [1, 2] }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content node must be a JSON object")
      end

      it "rejects rich_content with non-object elements" do
        post @action, params: @params.merge(rich_content: ["oops"])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array of content page objects")
      end

      it "rejects non-array files" do
        post @action, params: @params.merge(files: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array")
      end

      it "rejects file objects missing url" do
        post @action, params: @params.merge(files: [{ display_name: "No URL" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must include a url string")
      end

      it "rejects file urls that are not the seller's S3 path" do
        post @action, params: @params.merge(files: [{ url: "https://evil.com/malware.exe" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects file urls with path traversal" do
        post @action, params: @params.merge(files: [{ url: "#{S3_BASE_URL}attachments/#{@user.external_id}/../../other-user/secret.pdf" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects file urls from another seller's S3 path" do
        other_user = create(:user)
        post @action, params: @params.merge(files: [{ url: "#{S3_BASE_URL}attachments/#{other_user.external_id}/test/original/stolen.pdf" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects files with non-object elements" do
        post @action, params: @params.merge(files: ["oops"])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array of file objects")
      end

      describe "rejecting legacy upload fields" do
        %i[file preview thumbnail].each do |field|
          it "rejects #{field} sent as a string" do
            post @action, params: @params.merge(field => "something.pdf")

            expect(response).to be_successful
            expect(response.parsed_body["success"]).to be false
            expect(response.parsed_body["message"]).to start_with("'#{field}' is not an accepted parameter on POST /v2/products.")
          end

          it "rejects #{field} sent as a multipart upload" do
            upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
            post @action, params: @params.merge(field => upload)

            expect(response).to be_successful
            expect(response.parsed_body["success"]).to be false
            expect(response.parsed_body["message"]).to start_with("'#{field}' is not an accepted parameter on POST /v2/products.")
          end
        end

        it "points file rejections to the full presign and complete flow" do
          post @action, params: @params.merge(file: "something.pdf")

          message = response.parsed_body["message"]
          expect(message).to include("POST /v2/files/presign")
          expect(message).to include("POST /v2/files/complete")
          expect(message).to include("files[][url]")
        end

        it "points preview rejections to the covers endpoint rather than presign" do
          post @action, params: @params.merge(preview: "cover.png")

          message = response.parsed_body["message"]
          expect(message).to include("/v2/products/:id/covers")
          expect(message).to include("Create the product first")
          expect(message).not_to include("POST /v2/files/presign")
        end

        it "points thumbnail rejections to the thumbnail endpoint rather than presign" do
          post @action, params: @params.merge(thumbnail: "thumb.png")

          message = response.parsed_body["message"]
          expect(message).to include("/v2/products/:id/thumbnail")
          expect(message).to include("Create the product first")
          expect(message).not_to include("POST /v2/files/presign")
        end

        %i[file preview thumbnail].each do |field|
          [nil, "", {}, { url: "" }, { signed_blob_id: "" }, { nested: { key: "" } }, [nil, ""]].each do |blank_value|
            it "ignores #{field} when sent as #{blank_value.inspect}" do
              post @action, params: @params.merge(field => blank_value)

              expect(response).to be_successful
              expect(response.parsed_body["success"]).to be true
            end
          end
        end
      end

      it "defaults taxonomy to 'other' when not specified" do
        post @action, params: @params

        product = @user.links.last
        expect(product.taxonomy.slug).to eq("other")
      end

      it "uses the seller's currency when currency is omitted" do
        @user.update!(currency_type: "gbp")

        post @action, params: @params

        product = @user.links.last
        expect(product.price_currency_type).to eq("gbp")
      end

      it "rejects invalid taxonomy_id" do
        post @action, params: @params.merge(taxonomy_id: 999999)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("Invalid taxonomy_id")
      end

      it "creates a product with rich content pages" do
        rich_content = [
          {
            title: "Getting Started",
            description: {
              type: "doc",
              content: [
                { type: "paragraph", content: [{ type: "text", text: "Welcome!" }] }
              ]
            }
          },
          {
            title: "Chapter 2",
            description: {
              type: "doc",
              content: [
                { type: "paragraph", content: [{ type: "text", text: "More content" }] }
              ]
            }
          }
        ]

        post @action, params: @params.merge(rich_content:)

        expect(response).to be_successful
        product = @user.links.last
        expect(product.alive_rich_contents.count).to eq(2)
        expect(product.alive_rich_contents.order(:position).first.title).to eq("Getting Started")
        expect(product.alive_rich_contents.order(:position).last.title).to eq("Chapter 2")
      end

      it "creates a product with files" do
        s3_key = "attachments/#{@user.external_id}/test/original/course.pdf"
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key).put(body: "test content")

        files = [
          {
            url: "#{S3_BASE_URL}#{s3_key}",
            display_name: "Course PDF"
          }
        ]

        post @action, params: @params.merge(files:)

        body = response.parsed_body
        expect(body["success"]).to eq(true), "Expected success but got: #{body.inspect}"
        product = @user.links.last
        expect(product).to be_present
        expect(product.product_files.alive.count).to eq(1)
        expect(product.product_files.alive.first.display_name).to eq("Course PDF")
      end

      it "creates a product with files and rich content referencing those files" do
        temp_id = "temp-file-1"
        s3_key = "attachments/#{@user.external_id}/test/original/doc.pdf"
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(s3_key).put(body: "test content")

        file_url = "#{S3_BASE_URL}#{s3_key}"
        files = [{ id: temp_id, url: file_url, display_name: "Doc" }]
        rich_content = [
          {
            title: "Page 1",
            description: {
              type: "doc",
              content: [
                { type: "fileEmbed", attrs: { id: temp_id, uid: SecureRandom.uuid } }
              ]
            }
          }
        ]

        post @action, params: @params.merge(files:, rich_content:)

        body = response.parsed_body
        expect(body["success"]).to eq(true), "Expected success but got: #{body.inspect}"
        product = @user.links.last
        expect(product.product_files.alive.count).to eq(1)
        expect(product.alive_rich_contents.count).to eq(1)

        real_file_id = product.product_files.alive.first.external_id
        embed_id = product.alive_rich_contents.first.description.dig(0, "attrs", "id")
        expect(embed_id).to eq(real_file_id)
      end

      it "processes upsell-card markup in description" do
        upsell_product = create(:product, user: @user)
        description = %(<p>Check this out</p><upsell-card productid="#{upsell_product.external_id}"></upsell-card>)

        post @action, params: @params.merge(description:)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
        product = @user.links.last
        parsed = Nokogiri::HTML.fragment(product.description)
        upsell_card = parsed.at_css("upsell-card")
        expect(upsell_card).to be_present
        expect(upsell_card["id"]).to be_present
        expect(Upsell.find_by_external_id(upsell_card["id"])).to be_present
      end

      it "returns the product in the response" do
        post @action, params: @params

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["product"]).to be_present
        expect(body["product"]["name"]).to eq("Some product")
        expect(body["product"]["price"]).to eq(200)
        expect(body["product"]["published"]).to be false
      end
    end

    describe "when logged in with account scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
        @params.merge!(access_token: @token.token)
      end

      it "creates a product via API key auth" do
        expect do
          post @action, params: @params
        end.to change { @user.links.count }.by(1)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
      end
    end
  end

  describe "GET 'show'" do
    before do
      @product = create(:product, user: @user, description: "des1")

      @action = :show
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in without view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          product: @product
        }.as_json(api_scopes: ["edit_products"]))
      end

      describe "purchasing power parity", :vcr do
        before do
          # The VCR cassette for PPP data is from 2025, so this prevents the worker complaining it's out of date
          travel_to Date.new(2025, 1, 1)
          UpdatePurchasingPowerParityFactorsWorker.new.perform
          @product.update!(price_cents: 1000)
          @user.update!(purchasing_power_parity_enabled: true)
        end

        it "includes the purchasing power parity prices" do
          @user.update!(purchasing_power_parity_limit: 50)
          get :show, params: @params
          expect(response.parsed_body["product"]["purchasing_power_parity_prices"]).to eq({ "AD" => 740, "AE" => 1000, "AF" => 500, "AG" => 680, "AI" => 1000, "AL" => 500, "AM" => 500, "AO" => 1000, "AQ" => 1000, "AR" => 1000, "AS" => 1000, "AT" => 1000, "AU" => 1000, "AW" => 750, "AX" => 1000, "AZ" => 650, "BA" => 500, "BB" => 1000, "BD" => 500, "BE" => 1000, "BF" => 500, "BG" => 500, "BH" => 1000, "BI" => 560, "BJ" => 500, "BL" => 1000, "BM" => 1000, "BN" => 1000, "BO" => 500, "BQ" => 1000, "BR" => 1000, "BS" => 1000, "BT" => 500, "BV" => 1000, "BW" => 680, "BY" => 1000, "BZ" => 550, "CA" => 1000, "CC" => 1000, "CD" => 1000, "CF" => 500, "CG" => 500, "CH" => 1000, "CI" => 500, "CK" => 1000, "CL" => 1000, "CM" => 500, "CN" => 580, "CO" => 760, "CR" => 640, "CU" => 1000, "CV" => 550, "CW" => 690, "CX" => 1000, "CY" => 690, "CZ" => 620, "DE" => 1000, "DJ" => 500, "DK" => 1000, "DM" => 510, "DO" => 610, "DZ" => 570, "EC" => 500, "EE" => 690, "EG" => 790, "EH" => 1000, "ER" => 500, "ES" => 1000, "ET" => 1000, "FI" => 1000, "FJ" => 500, "FK" => 1000, "FM" => 1000, "FO" => 1000, "FR" => 1000, "GA" => 500, "GB" => 1000, "GD" => 600, "GE" => 520, "GF" => 1000, "GG" => 1000, "GH" => 1000, "GI" => 1000, "GL" => 500, "GM" => 570, "GN" => 500, "GP" => 1000, "GQ" => 500, "GR" => 640, "GS" => 1000, "GT" => 500, "GU" => 1000, "GW" => 500, "GY" => 500, "HK" => 1000, "HM" => 1000, "HN" => 580, "HR" => 530, "HT" => 1000, "HU" => 690, "ID" => 530, "IE" => 1000, "IL" => 1000, "IM" => 1000, "IN" => 500, "IO" => 1000, "IQ" => 500, "IR" => 1000, "IS" => 1000, "IT" => 1000, "JE" => 1000, "JM" => 1000, "JO" => 500, "JP" => 1000, "KE" => 500, "KG" => 520, "KH" => 500, "KI" => 1000, "KM" => 500, "KN" => 670, "KP" => 500, "KR" => 1000, "KW" => 1000, "KY" => 1000, "KZ" => 1000, "LA" => 500, "LB" => 500, "LC" => 520, "LI" => 1000, "LK" => 760, "LR" => 500, "LS" => 720, "LT" => 600, "LU" => 1000, "LV" => 620, "LY" => 1000, "MA" => 500, "MC" => 1000, "MD" => 580, "ME" => 500, "MF" => 1000, "MG" => 550, "MH" => 1000, "MK" => 500, "ML" => 500, "MM" => 1000, "MN" => 790, "MO" => 1000, "MP" => 1000, "MQ" => 1000, "MR" => 1000, "MS" => 1000, "MT" => 690, "MU" => 590, "MV" => 510, "MW" => 1000, "MX" => 710, "MY" => 500, "MZ" => 1000, "NA" => 1000, "NC" => 500, "NE" => 500, "NF" => 1000, "NG" => 1000, "NI" => 500, "NL" => 1000, "NO" => 1000, "NP" => 500, "NR" => 1000, "NU" => 1000, "NZ" => 1000, "OM" => 1000, "PA" => 500, "PE" => 650, "PF" => 500, "PG" => 1000, "PH" => 500, "PK" => 620, "PL" => 540, "PM" => 1000, "PN" => 1000, "PR" => 770, "PS" => 500, "PT" => 1000, "PW" => 1000, "PY" => 570, "QA" => 1000, "RE" => 1000, "RO" => 520, "RS" => 540, "RU" => 1000, "RW" => 570, "SA" => 1000, "SB" => 1000, "SC" => 560, "SD" => 1000, "SE" => 1000, "SG" => 1000, "SH" => 1000, "SI" => 670, "SJ" => 1000, "SK" => 620, "SL" => 500, "SM" => 1000, "SN" => 500, "SO" => 1000, "SR" => 1000, "SS" => 1000, "ST" => 500, "SV" => 500, "SX" => 760, "SY" => 500, "SZ" => 730, "TC" => 1000, "TD" => 500, "TF" => 1000, "TG" => 500, "TH" => 500, "TJ" => 530, "TK" => 1000, "TL" => 500, "TM" => 510, "TN" => 580, "TO" => 570, "TR" => 1000, "TT" => 600, "TV" => 1000, "TW" => 1000, "TZ" => 500, "UA" => 1000, "UG" => 500, "UM" => 1000, "US" => 1000, "UY" => 1000, "UZ" => 1000, "VA" => 1000, "VC" => 520, "VE" => 1000, "VG" => 1000, "VI" => 1000, "VN" => 500, "VU" => 1000, "WF" => 1000, "WS" => 700, "YE" => 500, "YT" => 1000, "ZA" => 620, "ZM" => 1000, "ZW" => 1000, "XK" => 1000 })
        end

        it "excludes the purchasing power parity prices when disabled" do
          @product.update! purchasing_power_parity_disabled: true
          get :show, params: @params
          expect(response.parsed_body["product"]["purchasing_power_parity_prices"]).to eq(nil)
        end

        context "when the product is a versioned product" do
          let(:versioned_product) { create(:product_with_digital_versions, user: @user) }

          before do
            versioned_product.alive_variants.second.update!(price_difference_cents: 1000)
            @params[:id] = versioned_product.external_id
          end

          it "includes the purchasing power parity prices" do
            get :show, params: @params
            expect(response.parsed_body["product"]["variants"][0]["options"][0]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 99, "AE" => 100, "AF" => 99, "AG" => 99, "AI" => 100, "AL" => 99, "AM" => 99, "AO" => 100, "AQ" => 100, "AR" => 100, "AS" => 100, "AT" => 100, "AU" => 100, "AW" => 99, "AX" => 100, "AZ" => 99, "BA" => 99, "BB" => 100, "BD" => 99, "BE" => 100, "BF" => 99, "BG" => 99, "BH" => 100, "BI" => 99, "BJ" => 99, "BL" => 100, "BM" => 100, "BN" => 100, "BO" => 99, "BQ" => 100, "BR" => 100, "BS" => 100, "BT" => 99, "BV" => 100, "BW" => 99, "BY" => 100, "BZ" => 99, "CA" => 100, "CC" => 100, "CD" => 100, "CF" => 99, "CG" => 99, "CH" => 100, "CI" => 99, "CK" => 100, "CL" => 100, "CM" => 99, "CN" => 99, "CO" => 99, "CR" => 99, "CU" => 100, "CV" => 99, "CW" => 99, "CX" => 100, "CY" => 99, "CZ" => 99, "DE" => 100, "DJ" => 99, "DK" => 100, "DM" => 99, "DO" => 99, "DZ" => 99, "EC" => 99, "EE" => 99, "EG" => 99, "EH" => 100, "ER" => 99, "ES" => 100, "ET" => 100, "FI" => 100, "FJ" => 99, "FK" => 100, "FM" => 100, "FO" => 100, "FR" => 100, "GA" => 99, "GB" => 100, "GD" => 99, "GE" => 99, "GF" => 100, "GG" => 100, "GH" => 100, "GI" => 100, "GL" => 99, "GM" => 99, "GN" => 99, "GP" => 100, "GQ" => 99, "GR" => 99, "GS" => 100, "GT" => 99, "GU" => 100, "GW" => 99, "GY" => 99, "HK" => 100, "HM" => 100, "HN" => 99, "HR" => 99, "HT" => 100, "HU" => 99, "ID" => 99, "IE" => 100, "IL" => 100, "IM" => 100, "IN" => 99, "IO" => 100, "IQ" => 99, "IR" => 100, "IS" => 100, "IT" => 100, "JE" => 100, "JM" => 100, "JO" => 99, "JP" => 100, "KE" => 99, "KG" => 99, "KH" => 99, "KI" => 100, "KM" => 99, "KN" => 99, "KP" => 99, "KR" => 100, "KW" => 100, "KY" => 100, "KZ" => 100, "LA" => 99, "LB" => 99, "LC" => 99, "LI" => 100, "LK" => 99, "LR" => 99, "LS" => 99, "LT" => 99, "LU" => 100, "LV" => 99, "LY" => 100, "MA" => 99, "MC" => 100, "MD" => 99, "ME" => 99, "MF" => 100, "MG" => 99, "MH" => 100, "MK" => 99, "ML" => 99, "MM" => 100, "MN" => 99, "MO" => 100, "MP" => 100, "MQ" => 100, "MR" => 100, "MS" => 100, "MT" => 99, "MU" => 99, "MV" => 99, "MW" => 100, "MX" => 99, "MY" => 99, "MZ" => 100, "NA" => 100, "NC" => 99, "NE" => 99, "NF" => 100, "NG" => 100, "NI" => 99, "NL" => 100, "NO" => 100, "NP" => 99, "NR" => 100, "NU" => 100, "NZ" => 100, "OM" => 100, "PA" => 99, "PE" => 99, "PF" => 99, "PG" => 100, "PH" => 99, "PK" => 99, "PL" => 99, "PM" => 100, "PN" => 100, "PR" => 99, "PS" => 99, "PT" => 100, "PW" => 100, "PY" => 99, "QA" => 100, "RE" => 100, "RO" => 99, "RS" => 99, "RU" => 100, "RW" => 99, "SA" => 100, "SB" => 100, "SC" => 99, "SD" => 100, "SE" => 100, "SG" => 100, "SH" => 100, "SI" => 99, "SJ" => 100, "SK" => 99, "SL" => 99, "SM" => 100, "SN" => 99, "SO" => 100, "SR" => 100, "SS" => 100, "ST" => 99, "SV" => 99, "SX" => 99, "SY" => 99, "SZ" => 99, "TC" => 100, "TD" => 99, "TF" => 100, "TG" => 99, "TH" => 99, "TJ" => 99, "TK" => 100, "TL" => 99, "TM" => 99, "TN" => 99, "TO" => 99, "TR" => 100, "TT" => 99, "TV" => 100, "TW" => 100, "TZ" => 99, "UA" => 100, "UG" => 99, "UM" => 100, "US" => 100, "UY" => 100, "UZ" => 100, "VA" => 100, "VC" => 99, "VE" => 100, "VG" => 100, "VI" => 100, "VN" => 99, "VU" => 100, "WF" => 100, "WS" => 99, "YE" => 99, "YT" => 100, "ZA" => 99, "ZM" => 100, "ZW" => 100, "XK" => 100
                     })
            expect(response.parsed_body["product"]["variants"][0]["options"][1]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 814, "AE" => 1100, "AF" => 440, "AG" => 748, "AI" => 1100, "AL" => 440, "AM" => 440, "AO" => 1100, "AQ" => 1100, "AR" => 1100, "AS" => 1100, "AT" => 1100, "AU" => 1100, "AW" => 825, "AX" => 1100, "AZ" => 715, "BA" => 473, "BB" => 1100, "BD" => 440, "BE" => 1100, "BF" => 440, "BG" => 528, "BH" => 1100, "BI" => 616, "BJ" => 440, "BL" => 1100, "BM" => 1100, "BN" => 1100, "BO" => 440, "BQ" => 1100, "BR" => 1100, "BS" => 1100, "BT" => 440, "BV" => 1100, "BW" => 748, "BY" => 1100, "BZ" => 605, "CA" => 1100, "CC" => 1100, "CD" => 1100, "CF" => 506, "CG" => 462, "CH" => 1100, "CI" => 451, "CK" => 1100, "CL" => 1100, "CM" => 440, "CN" => 638, "CO" => 836, "CR" => 704, "CU" => 1100, "CV" => 605, "CW" => 759, "CX" => 1100, "CY" => 759, "CZ" => 682, "DE" => 1100, "DJ" => 539, "DK" => 1100, "DM" => 561, "DO" => 671, "DZ" => 627, "EC" => 451, "EE" => 759, "EG" => 869, "EH" => 1100, "ER" => 440, "ES" => 1100, "ET" => 1100, "FI" => 1100, "FJ" => 528, "FK" => 1100, "FM" => 1100, "FO" => 1100, "FR" => 1100, "GA" => 484, "GB" => 1100, "GD" => 660, "GE" => 572, "GF" => 1100, "GG" => 1100, "GH" => 1100, "GI" => 1100, "GL" => 440, "GM" => 627, "GN" => 451, "GP" => 1100, "GQ" => 495, "GR" => 704, "GS" => 1100, "GT" => 462, "GU" => 1100, "GW" => 440, "GY" => 440, "HK" => 1100, "HM" => 1100, "HN" => 638, "HR" => 583, "HT" => 1100, "HU" => 759, "ID" => 583, "IE" => 1100, "IL" => 1100, "IM" => 1100, "IN" => 440, "IO" => 1100, "IQ" => 484, "IR" => 1100, "IS" => 1100, "IT" => 1100, "JE" => 1100, "JM" => 1100, "JO" => 473, "JP" => 1100, "KE" => 550, "KG" => 572, "KH" => 440, "KI" => 1100, "KM" => 528, "KN" => 737, "KP" => 440, "KR" => 1100, "KW" => 1100, "KY" => 1100, "KZ" => 1100, "LA" => 539, "LB" => 440, "LC" => 572, "LI" => 1100, "LK" => 836, "LR" => 440, "LS" => 792, "LT" => 660, "LU" => 1100, "LV" => 682, "LY" => 1100, "MA" => 484, "MC" => 1100, "MD" => 638, "ME" => 484, "MF" => 1100, "MG" => 605, "MH" => 1100, "MK" => 440, "ML" => 440, "MM" => 1100, "MN" => 869, "MO" => 1100, "MP" => 1100, "MQ" => 1100, "MR" => 1100, "MS" => 1100, "MT" => 759, "MU" => 649, "MV" => 561, "MW" => 1100, "MX" => 781, "MY" => 495, "MZ" => 1100, "NA" => 1100, "NC" => 440, "NE" => 440, "NF" => 1100, "NG" => 1100, "NI" => 550, "NL" => 1100, "NO" => 1100, "NP" => 451, "NR" => 1100, "NU" => 1100, "NZ" => 1100, "OM" => 1100, "PA" => 517, "PE" => 715, "PF" => 440, "PG" => 1100, "PH" => 484, "PK" => 682, "PL" => 594, "PM" => 1100, "PN" => 1100, "PR" => 847, "PS" => 440, "PT" => 1100, "PW" => 1100, "PY" => 627, "QA" => 1100, "RE" => 1100, "RO" => 572, "RS" => 594, "RU" => 1100, "RW" => 627, "SA" => 1100, "SB" => 1100, "SC" => 616, "SD" => 1100, "SE" => 1100, "SG" => 1100, "SH" => 1100, "SI" => 737, "SJ" => 1100, "SK" => 682, "SL" => 440, "SM" => 1100, "SN" => 462, "SO" => 1100, "SR" => 1100, "SS" => 1100, "ST" => 440, "SV" => 473, "SX" => 836, "SY" => 440, "SZ" => 803, "TC" => 1100, "TD" => 473, "TF" => 1100, "TG" => 440, "TH" => 440, "TJ" => 583, "TK" => 1100, "TL" => 440, "TM" => 561, "TN" => 638, "TO" => 627, "TR" => 1100, "TT" => 660, "TV" => 1100, "TW" => 1100, "TZ" => 506, "UA" => 1100, "UG" => 550, "UM" => 1100, "US" => 1100, "UY" => 1100, "UZ" => 1100, "VA" => 1100, "VC" => 572, "VE" => 1100, "VG" => 1100, "VI" => 1100, "VN" => 440, "VU" => 1100, "WF" => 1100, "WS" => 770, "YE" => 440, "YT" => 1100, "ZA" => 682, "ZM" => 1100, "ZW" => 1100, "XK" => 1100
                     })
          end
        end

        context "when the product is a membership product" do
          let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: @user) }

          before do
            @params[:id] = membership.external_id
          end

          it "includes the purchasing power parity prices" do
            get :show, params: @params
            expect(response.parsed_body["product"]["variants"][0]["options"][1]["recurrence_prices"]["monthly"]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 370, "AE" => 500, "AF" => 200, "AG" => 340, "AI" => 500, "AL" => 200, "AM" => 200, "AO" => 500, "AQ" => 500, "AR" => 500, "AS" => 500, "AT" => 500, "AU" => 500, "AW" => 375, "AX" => 500, "AZ" => 325, "BA" => 215, "BB" => 500, "BD" => 200, "BE" => 500, "BF" => 200, "BG" => 240, "BH" => 500, "BI" => 280, "BJ" => 200, "BL" => 500, "BM" => 500, "BN" => 500, "BO" => 200, "BQ" => 500, "BR" => 500, "BS" => 500, "BT" => 200, "BV" => 500, "BW" => 340, "BY" => 500, "BZ" => 275, "CA" => 500, "CC" => 500, "CD" => 500, "CF" => 230, "CG" => 210, "CH" => 500, "CI" => 205, "CK" => 500, "CL" => 500, "CM" => 200, "CN" => 290, "CO" => 380, "CR" => 320, "CU" => 500, "CV" => 275, "CW" => 345, "CX" => 500, "CY" => 345, "CZ" => 310, "DE" => 500, "DJ" => 245, "DK" => 500, "DM" => 255, "DO" => 305, "DZ" => 285, "EC" => 205, "EE" => 345, "EG" => 395, "EH" => 500, "ER" => 200, "ES" => 500, "ET" => 500, "FI" => 500, "FJ" => 240, "FK" => 500, "FM" => 500, "FO" => 500, "FR" => 500, "GA" => 220, "GB" => 500, "GD" => 300, "GE" => 260, "GF" => 500, "GG" => 500, "GH" => 500, "GI" => 500, "GL" => 200, "GM" => 285, "GN" => 205, "GP" => 500, "GQ" => 225, "GR" => 320, "GS" => 500, "GT" => 210, "GU" => 500, "GW" => 200, "GY" => 200, "HK" => 500, "HM" => 500, "HN" => 290, "HR" => 265, "HT" => 500, "HU" => 345, "ID" => 265, "IE" => 500, "IL" => 500, "IM" => 500, "IN" => 200, "IO" => 500, "IQ" => 220, "IR" => 500, "IS" => 500, "IT" => 500, "JE" => 500, "JM" => 500, "JO" => 215, "JP" => 500, "KE" => 250, "KG" => 260, "KH" => 200, "KI" => 500, "KM" => 240, "KN" => 335, "KP" => 200, "KR" => 500, "KW" => 500, "KY" => 500, "KZ" => 500, "LA" => 245, "LB" => 200, "LC" => 260, "LI" => 500, "LK" => 380, "LR" => 200, "LS" => 360, "LT" => 300, "LU" => 500, "LV" => 310, "LY" => 500, "MA" => 220, "MC" => 500, "MD" => 290, "ME" => 220, "MF" => 500, "MG" => 275, "MH" => 500, "MK" => 200, "ML" => 200, "MM" => 500, "MN" => 395, "MO" => 500, "MP" => 500, "MQ" => 500, "MR" => 500, "MS" => 500, "MT" => 345, "MU" => 295, "MV" => 255, "MW" => 500, "MX" => 355, "MY" => 225, "MZ" => 500, "NA" => 500, "NC" => 200, "NE" => 200, "NF" => 500, "NG" => 500, "NI" => 250, "NL" => 500, "NO" => 500, "NP" => 205, "NR" => 500, "NU" => 500, "NZ" => 500, "OM" => 500, "PA" => 235, "PE" => 325, "PF" => 200, "PG" => 500, "PH" => 220, "PK" => 310, "PL" => 270, "PM" => 500, "PN" => 500, "PR" => 385, "PS" => 200, "PT" => 500, "PW" => 500, "PY" => 285, "QA" => 500, "RE" => 500, "RO" => 260, "RS" => 270, "RU" => 500, "RW" => 285, "SA" => 500, "SB" => 500, "SC" => 280, "SD" => 500, "SE" => 500, "SG" => 500, "SH" => 500, "SI" => 335, "SJ" => 500, "SK" => 310, "SL" => 200, "SM" => 500, "SN" => 210, "SO" => 500, "SR" => 500, "SS" => 500, "ST" => 200, "SV" => 215, "SX" => 380, "SY" => 200, "SZ" => 365, "TC" => 500, "TD" => 215, "TF" => 500, "TG" => 200, "TH" => 200, "TJ" => 265, "TK" => 500, "TL" => 200, "TM" => 255, "TN" => 290, "TO" => 285, "TR" => 500, "TT" => 300, "TV" => 500, "TW" => 500, "TZ" => 230, "UA" => 500, "UG" => 250, "UM" => 500, "US" => 500, "UY" => 500, "UZ" => 500, "VA" => 500, "VC" => 260, "VE" => 500, "VG" => 500, "VI" => 500, "VN" => 200, "VU" => 500, "WF" => 500, "WS" => 350, "YE" => 200, "YT" => 500, "ZA" => 310, "ZM" => 500, "ZW" => 500, "XK" => 500
                     })
            expect(response.parsed_body["product"]["variants"][0]["options"][0]["recurrence_prices"]["monthly"]["purchasing_power_parity_prices"])
              .to eq({
                       "AD" => 222, "AE" => 300, "AF" => 120, "AG" => 204, "AI" => 300, "AL" => 120, "AM" => 120, "AO" => 300, "AQ" => 300, "AR" => 300, "AS" => 300, "AT" => 300, "AU" => 300, "AW" => 225, "AX" => 300, "AZ" => 195, "BA" => 129, "BB" => 300, "BD" => 120, "BE" => 300, "BF" => 120, "BG" => 144, "BH" => 300, "BI" => 168, "BJ" => 120, "BL" => 300, "BM" => 300, "BN" => 300, "BO" => 120, "BQ" => 300, "BR" => 300, "BS" => 300, "BT" => 120, "BV" => 300, "BW" => 204, "BY" => 300, "BZ" => 165, "CA" => 300, "CC" => 300, "CD" => 300, "CF" => 138, "CG" => 126, "CH" => 300, "CI" => 123, "CK" => 300, "CL" => 300, "CM" => 120, "CN" => 174, "CO" => 228, "CR" => 192, "CU" => 300, "CV" => 165, "CW" => 207, "CX" => 300, "CY" => 207, "CZ" => 186, "DE" => 300, "DJ" => 147, "DK" => 300, "DM" => 153, "DO" => 183, "DZ" => 171, "EC" => 123, "EE" => 207, "EG" => 237, "EH" => 300, "ER" => 120, "ES" => 300, "ET" => 300, "FI" => 300, "FJ" => 144, "FK" => 300, "FM" => 300, "FO" => 300, "FR" => 300, "GA" => 132, "GB" => 300, "GD" => 180, "GE" => 156, "GF" => 300, "GG" => 300, "GH" => 300, "GI" => 300, "GL" => 120, "GM" => 171, "GN" => 123, "GP" => 300, "GQ" => 135, "GR" => 192, "GS" => 300, "GT" => 126, "GU" => 300, "GW" => 120, "GY" => 120, "HK" => 300, "HM" => 300, "HN" => 174, "HR" => 159, "HT" => 300, "HU" => 207, "ID" => 159, "IE" => 300, "IL" => 300, "IM" => 300, "IN" => 120, "IO" => 300, "IQ" => 132, "IR" => 300, "IS" => 300, "IT" => 300, "JE" => 300, "JM" => 300, "JO" => 129, "JP" => 300, "KE" => 150, "KG" => 156, "KH" => 120, "KI" => 300, "KM" => 144, "KN" => 201, "KP" => 120, "KR" => 300, "KW" => 300, "KY" => 300, "KZ" => 300, "LA" => 147, "LB" => 120, "LC" => 156, "LI" => 300, "LK" => 228, "LR" => 120, "LS" => 216, "LT" => 180, "LU" => 300, "LV" => 186, "LY" => 300, "MA" => 132, "MC" => 300, "MD" => 174, "ME" => 132, "MF" => 300, "MG" => 165, "MH" => 300, "MK" => 120, "ML" => 120, "MM" => 300, "MN" => 237, "MO" => 300, "MP" => 300, "MQ" => 300, "MR" => 300, "MS" => 300, "MT" => 207, "MU" => 177, "MV" => 153, "MW" => 300, "MX" => 213, "MY" => 135, "MZ" => 300, "NA" => 300, "NC" => 120, "NE" => 120, "NF" => 300, "NG" => 300, "NI" => 150, "NL" => 300, "NO" => 300, "NP" => 123, "NR" => 300, "NU" => 300, "NZ" => 300, "OM" => 300, "PA" => 141, "PE" => 195, "PF" => 120, "PG" => 300, "PH" => 132, "PK" => 186, "PL" => 162, "PM" => 300, "PN" => 300, "PR" => 231, "PS" => 120, "PT" => 300, "PW" => 300, "PY" => 171, "QA" => 300, "RE" => 300, "RO" => 156, "RS" => 162, "RU" => 300, "RW" => 171, "SA" => 300, "SB" => 300, "SC" => 168, "SD" => 300, "SE" => 300, "SG" => 300, "SH" => 300, "SI" => 201, "SJ" => 300, "SK" => 186, "SL" => 120, "SM" => 300, "SN" => 126, "SO" => 300, "SR" => 300, "SS" => 300, "ST" => 120, "SV" => 129, "SX" => 228, "SY" => 120, "SZ" => 219, "TC" => 300, "TD" => 129, "TF" => 300, "TG" => 120, "TH" => 120, "TJ" => 159, "TK" => 300, "TL" => 120, "TM" => 153, "TN" => 174, "TO" => 171, "TR" => 300, "TT" => 180, "TV" => 300, "TW" => 300, "TZ" => 138, "UA" => 300, "UG" => 150, "UM" => 300, "US" => 300, "UY" => 300, "UZ" => 300, "VA" => 300, "VC" => 156, "VE" => 300, "VG" => 300, "VI" => 300, "VN" => 120, "VU" => 300, "WF" => 300, "WS" => 210, "YE" => 120, "YT" => 300, "ZA" => 186, "ZM" => 300, "ZW" => 300, "XK" => 300
                     })
            expect(response.parsed_body["product"]["purchasing_power_parity_prices"].values.all? { _1 == 0 }).to eq(true)
          end
        end
      end
    end

    describe "product JSON fields" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "includes rich_content array" do
        create(:rich_content, entity: @product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "hello" }] }])

        get :show, params: @params
        expect(response.parsed_body["product"]["rich_content"]).to be_an(Array)
        expect(response.parsed_body["product"]["rich_content"].first["description"]).to eq({ "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "hello" }] }] })
      end

      it "includes has_same_rich_content_for_all_variants" do
        get :show, params: @params
        expect(response.parsed_body["product"]).to have_key("has_same_rich_content_for_all_variants")
      end

      it "includes files array with signed URLs for uploaded files" do
        file = create(:product_file, link: @product, url: "#{S3_BASE_URL}specs/test.pdf")

        get :show, params: @params
        files = response.parsed_body["product"]["files"]
        expect(files).to be_an(Array)
        expect(files.first["id"]).to eq(file.external_id)
        expect(files.first["filetype"]).to eq(file.filetype)
        expect(files.first["filegroup"]).to eq(file.filegroup)
        expect(files.first["url"]).not_to eq(file.url)
        expect(files.first["url"]).to be_present
      end

      it "gracefully skips files with missing S3 objects" do
        good_file = create(:product_file, link: @product, url: "#{S3_BASE_URL}specs/test.pdf")
        bad_file = create(:product_file, link: @product, url: "#{S3_BASE_URL}attachments/missing-guid/original/gone.zip")

        bad_url = bad_file.url
        allow_any_instance_of(ProductFile).to receive(:signed_url) do |product_file|
          raise Aws::S3::Errors::NotFound.new(nil, "Not Found") if product_file.url == bad_url
          "https://signed.example.com/test.pdf"
        end

        get :show, params: @params
        expect(response).to be_successful
        files = response.parsed_body["product"]["files"]
        expect(files.length).to eq(1)
        expect(files.first["id"]).to eq(good_file.external_id)
      end

      it "includes raw URL for external link files" do
        create(:product_file, link: @product, url: "https://example.com/my-file.zip", filetype: "link")

        get :show, params: @params
        files = response.parsed_body["product"]["files"]
        expect(files.first["url"]).to eq("https://example.com/my-file.zip")
      end

      it "includes covers array and main_cover_id" do
        cover = create(:asset_preview, link: @product)

        get :show, params: @params
        expect(response.parsed_body["product"]["covers"]).to be_an(Array)
        expect(response.parsed_body["product"]["covers"].first["id"]).to eq(cover.guid)
        expect(response.parsed_body["product"]["main_cover_id"]).to eq(cover.guid)
      end

      it "includes bundle_products for bundle products" do
        bundle = create(:product, :bundle, user: @user)
        @params.merge!(id: bundle.external_id)

        get :show, params: @params
        expect(response.parsed_body["product"]["bundle_products"]).to be_an(Array)
        expect(response.parsed_body["product"]["bundle_products"].length).to eq(bundle.bundle_products.alive.count)
        expect(response.parsed_body["product"]["bundle_products"].first).to include("product_id", "quantity", "position")
      end

      it "includes empty bundle_products for non-bundle products" do
        get :show, params: @params
        expect(response.parsed_body["product"]["bundle_products"]).to eq([])
      end

      it "includes rich_content in variant options" do
        variant_product = create(:product_with_digital_versions, user: @user)
        variant = variant_product.alive_variants.first
        create(:rich_content, entity: variant, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "variant content" }] }])
        @params.merge!(id: variant_product.external_id)

        get :show, params: @params
        options = response.parsed_body["product"]["variants"][0]["options"]
        first_option = options.find { |o| o["rich_content"].any? }
        expect(first_option).to be_present
        expect(first_option["rich_content"].first["description"]).to eq({ "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "variant content" }] }] })
      end
    end

    describe "when logged in with view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
        @params.merge!(access_token: @token.token)
      end

      it "shows me my products" do
        get :show, params: @params
        expect(response.parsed_body["product"]).to eq(@product.as_json(api_scopes: ["view_sales"]))
      end

      it "includes deprecated `custom_delivery_url` attribute" do
        get :show, params: @params.merge(id: create(:product, user: @user).external_id)
        expect(response.parsed_body["product"]).to include("custom_delivery_url" => nil)
      end
    end

    it "grants access with the account scope and includes sales data" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get :show, params: { id: @product.external_id, access_token: token.token }
      expect(response).to be_successful
      expect(response.parsed_body["product"]).to have_key("sales_count")
    end

    context "when product is a tiered membership with no default tier" do
      before do
        token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @product = create(:membership_product, user: @user)
        @product.tier_category.tiers.each { |tier| tier.update_columns(deleted_at: Time.current) }
        @product.reload
        @params = { id: @product.external_id, access_token: token.token }
      end

      it "returns product data without raising an error" do
        get :show, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
        expect(response.parsed_body["product"]).to be_present
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @product = create(:product, user: @user, description: "des1", price_cents: 500)
      @action = :update
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "updates name and description" do
        put @action, params: @params.merge(name: "Updated Name", description: "<p>New description</p>")
        expect(response.parsed_body["success"]).to be(true)
        @product.reload
        expect(@product.name).to eq("Updated Name")
        expect(@product.description).to include("New description")
      end

      it "updates price via the price param" do
        put @action, params: @params.merge(price: 1099)
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.price_cents).to eq(1099)
      end

      it "rejects price for tiered membership products" do
        membership = create(:membership_product, user: @user)
        put @action, params: @params.merge(id: membership.external_id, price: 2000)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("tiered membership")
      end

      it "rejects unsupported price_currency_type" do
        put @action, params: @params.merge(price_currency_type: "xyz")
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("not a supported currency")
      end

      it "processes description through SaveContentUpsellsService" do
        expect_any_instance_of(SaveContentUpsellsService).to receive(:from_html).and_call_original
        put @action, params: @params.merge(description: "<p>test</p>")
        expect(response.parsed_body["success"]).to be(true)
      end

      it "stores custom_summary in json_data" do
        put @action, params: @params.merge(custom_summary: "A custom summary")
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.json_data["custom_summary"]).to eq("A custom summary")
      end

      it "sets tags" do
        put @action, params: @params.merge(tags: ["ruby", "rails"])
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.tags.pluck(:name)).to match_array(["ruby", "rails"])
      end

      it "replaces existing tags" do
        @product.save_tags!(["ruby", "rails"])
        put @action, params: @params.merge(tags: ["ruby"])
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.tags.pluck(:name)).to match_array(["ruby"])
      end

      it "rejects non-array tags" do
        put @action, params: @params.merge(tags: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("tags must be an array")
      end

      it "rejects tags with non-string elements" do
        put @action, params: @params.merge(tags: ["valid", { nested: "hash" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("tags must be an array of strings")
      end

      it "rejects non-array rich_content" do
        put @action, params: @params.merge(rich_content: { title: "oops", description: { type: "doc" } })

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array")
      end

      it "rejects rich_content with non-object elements" do
        put @action, params: @params.merge(rich_content: ["oops"])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array of content page objects")
      end

      it "rejects rich_content with string description" do
        put @action, params: @params.merge(rich_content: [{ title: "Page", description: "a string" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("description must be a JSON object or array")
      end

      it "rejects rich_content with non-array wrapper content" do
        put @action, params: @params.merge(rich_content: [{ description: { type: "doc", content: "oops" } }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content must be an array")
      end

      it "rejects rich_content with non-object content nodes in wrapper" do
        put @action, params: @params.merge(rich_content: [{ description: { type: "doc", content: [1, "text"] } }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content node must be a JSON object")
      end

      it "rejects rich_content with non-object content nodes in raw array" do
        put @action, params: @params.merge(rich_content: [{ description: [1, 2] }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("content node must be a JSON object")
      end

      it "rejects non-array files" do
        put @action, params: @params.merge(files: { url: "https://example.com/file.pdf" })

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array")
      end

      it "rejects files with non-object elements" do
        put @action, params: @params.merge(files: ["oops"])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array of file objects")
      end

      it "rejects file objects missing url when no existing file id is provided" do
        put @action, params: @params.merge(files: [{ display_name: "No URL" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference an existing file by id or include a url")
      end

      it "rejects file urls that are not the seller's S3 path" do
        put @action, params: @params.merge(files: [{ url: "https://evil.com/malware.exe" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects file urls with path traversal" do
        put @action, params: @params.merge(files: [{ url: "#{S3_BASE_URL}attachments/#{@user.external_id}/../../other-user/secret.pdf" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects file urls from another seller's S3 path" do
        other_user = create(:user)
        put @action, params: @params.merge(files: [{ url: "#{S3_BASE_URL}attachments/#{other_user.external_id}/test/original/stolen.pdf" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects existing file id with a different url" do
        existing_file = create(:product_file, link: @product)
        put @action, params: @params.merge(files: [{ id: existing_file.external_id, url: "https://evil.com/malware.exe" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects foreign product file id with malicious url" do
        other_product = create(:product, user: create(:user))
        other_file = create(:product_file, link: other_product)
        put @action, params: @params.merge(files: [{ id: other_file.external_id, url: "https://evil.com/malware.exe" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference your own uploaded files")
      end

      it "rejects files containing uploaded file objects" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
        put @action, params: @params.merge(files: [upload])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array of file objects")
      end

      it "rejects rich_content containing uploaded file objects" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
        put @action, params: @params.merge(rich_content: [upload])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array of content page objects")
      end

      describe "rejecting legacy upload fields" do
        %i[file preview thumbnail].each do |field|
          it "rejects #{field} sent as a string" do
            put @action, params: @params.merge(field => "something.pdf")

            expect(response).to be_successful
            expect(response.parsed_body["success"]).to be false
            expect(response.parsed_body["message"]).to start_with("'#{field}' is not an accepted parameter on PUT /v2/products/:id.")
          end

          it "rejects #{field} sent as a multipart upload" do
            upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
            put @action, params: @params.merge(field => upload)

            expect(response).to be_successful
            expect(response.parsed_body["success"]).to be false
            expect(response.parsed_body["message"]).to start_with("'#{field}' is not an accepted parameter on PUT /v2/products/:id.")
          end
        end

        it "points file rejections to the full presign and complete flow and describes the preservation contract" do
          put @action, params: @params.merge(file: "something.pdf")

          message = response.parsed_body["message"]
          expect(message).to include("POST /v2/files/presign")
          expect(message).to include("POST /v2/files/complete")
          expect(message).to include("files[][url]")
          expect(message).to include("full replacement")
          expect(message).to include("include an entry with its id")
          expect(message).to include("files missing from the array are removed")
        end

        it "points preview rejections to the covers endpoint rather than presign" do
          put @action, params: @params.merge(preview: "cover.png")

          message = response.parsed_body["message"]
          expect(message).to include("POST /v2/products/:id/covers")
          expect(message).not_to include("POST /v2/files/presign")
        end

        it "points thumbnail rejections to the thumbnail endpoint rather than presign" do
          put @action, params: @params.merge(thumbnail: "thumb.png")

          message = response.parsed_body["message"]
          expect(message).to include("POST /v2/products/:id/thumbnail")
          expect(message).not_to include("POST /v2/files/presign")
        end

        %i[file preview thumbnail].each do |field|
          [nil, "", {}, { url: "" }, { signed_blob_id: "" }, { nested: { key: "" } }, [nil, ""]].each do |blank_value|
            it "ignores #{field} when sent as #{blank_value.inspect}" do
              put @action, params: @params.merge(field => blank_value, name: "Updated")

              expect(response).to be_successful
              expect(response.parsed_body["success"]).to be true
              expect(@product.reload.name).to eq("Updated")
            end
          end
        end
      end

      it "rejects non-array cover_ids" do
        put @action, params: @params.merge(cover_ids: "not-an-array")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("cover_ids must be an array")
      end

      it "rejects cover_ids containing uploaded file objects" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
        put @action, params: @params.merge(cover_ids: [upload])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("cover_ids must be an array of strings")
      end

      it "rejects files when numeric-keyed params normalize into non-hash elements" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
        put @action, params: @params.merge(files: [{ "0" => upload }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("must reference an existing file by id or include a url")
      end

      it "rejects rich_content when numeric-keyed params normalize into non-hash elements" do
        upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/smilie.png"), "image/png")
        put @action, params: @params.merge(rich_content: [{ "0" => upload }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array of content page objects")
      end

      it "does not change native_type" do
        original_type = @product.native_type
        put @action, params: @params.merge(native_type: "membership")
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.native_type).to eq(original_type)
      end

      it "returns validation errors in standard format" do
        put @action, params: @params.merge(name: "")
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to be_present
      end

      it "grants access with the account scope" do
        account_token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
        put @action, params: @params.merge(access_token: account_token.token, name: "Account Update")
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.name).to eq("Account Update")
      end

      it "returns warning when price change invalidates existing offer codes" do
        create(:offer_code, user: @user, products: [@product], amount_cents: 100)
        put @action, params: @params.merge(price: 150)
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["warning"]).to be_present
      end

      it "rolls back all changes on validation failure" do
        original_name = @product.name
        allow_any_instance_of(Link).to receive(:save!).and_raise(ActiveRecord::RecordNotSaved.new("failed", @product))
        put @action, params: @params.merge(name: "Should Not Persist", tags: ["new-tag"])
        expect(@product.reload.name).to eq(original_name)
        expect(@product.tags).to be_empty
      end

      it "does not touch omitted fields (partial update)" do
        @product.update!(description: "<p>original</p>")
        @product.save_tags!(["existing-tag"])
        @product.json_data["custom_summary"] = "original summary"
        @product.save!

        put @action, params: @params.merge(name: "Only Name Changed")
        expect(response.parsed_body["success"]).to be(true)
        @product.reload
        expect(@product.name).to eq("Only Name Changed")
        expect(@product.description).to include("original")
        expect(@product.tags.pluck(:name)).to eq(["existing-tag"])
        expect(@product.json_data["custom_summary"]).to eq("original summary")
      end

      it "updates rich content pages" do
        existing_rc = create(:rich_content, entity: @product, title: "Page 1", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Old" }] }], position: 0)

        put @action, params: @params.merge(rich_content: [
                                             { id: existing_rc.external_id, title: "Page 1 Updated", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "New" }] }] } },
                                             { title: "Page 2", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Brand new page" }] }] } }
                                           ])
        expect(response.parsed_body["success"]).to be(true)
        @product.reload
        pages = @product.alive_rich_contents.order(:position)
        expect(pages.count).to eq(2)
        expect(pages.first.title).to eq("Page 1 Updated")
        expect(pages.second.title).to eq("Page 2")
      end

      it "removes rich content pages not in the request" do
        create(:rich_content, entity: @product, title: "Will Be Removed", description: [], position: 0)

        put @action, params: @params.merge(rich_content: []), as: :json
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.alive_rich_contents.count).to eq(0)
      end

      it "updates files" do
        existing_file = create(:product_file, link: @product)
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(existing_file.s3_key).put(body: "test content")
        new_s3_key = "attachments/#{@user.external_id}/#{SecureRandom.hex}/original/new_file.pdf"
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(new_s3_key).put(body: "test content")
        new_file_url = "#{S3_BASE_URL}#{new_s3_key}"

        put @action, params: @params.merge(files: [
                                             { id: existing_file.external_id, url: existing_file.url, display_name: "Existing" },
                                             { url: new_file_url, display_name: "New File" }
                                           ])
        expect(response.parsed_body["success"]).to be(true)
        @product.reload
        alive_files = @product.product_files.alive
        expect(alive_files.count).to eq(2)
      end

      it "does not delete existing files when only rich_content changes" do
        file = create(:product_file, link: @product)
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(file.s3_key).put(body: "test content")
        put @action, params: @params.merge(rich_content: [
                                             { title: "Page 1", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "test" }] }] } }
                                           ])
        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload.alive?).to be(true)
      end

      it "does not delete existing rich content when only files change" do
        rc = create(:rich_content, entity: @product, title: "Keep", description: [], position: 0)
        put @action, params: @params.merge(files: []), as: :json
        expect(response.parsed_body["success"]).to be(true)
        expect(rc.reload.alive?).to be(true)
      end

      it "rejects removing a file still referenced by product-level rich content" do
        file = create(:product_file, link: @product)
        create(:rich_content, entity: @product, title: "Page", description: [
                 { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
               ], position: 0)

        put @action, params: @params.merge(files: []), as: :json
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("Cannot remove files")
        expect(file.reload.alive?).to be(true)
      end

      it "allows removing a file and its embed in the same request" do
        file = create(:product_file, link: @product)
        create(:rich_content, entity: @product, title: "Page", description: [
                 { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
               ], position: 0)

        put @action, params: @params.merge(
          files: [],
          rich_content: [{ title: "Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "No embed" }] }] } }]
        ), as: :json
        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload.alive?).to be(false)
      end

      it "treats id-only files[] entries as keep-unchanged for existing files" do
        file = create(:product_file, link: @product, display_name: "Keep me")

        put @action, params: @params.merge(files: [{ id: file.external_id }]), as: :json

        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload.alive?).to be(true)
        expect(file.display_name).to eq("Keep me")
      end

      it "preserves rich-content embeds when id-only files[] entries match existing files" do
        file = create(:product_file, link: @product)
        rc = create(:rich_content, entity: @product, title: "Page", description: [
                      { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
                    ], position: 0)

        put @action, params: @params.merge(files: [{ id: file.external_id }]), as: :json

        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload.alive?).to be(true)
        expect(rc.reload.description.first.dig("attrs", "id")).to eq(file.external_id)
      end

      it "rejects partial updates to an existing file that omit the canonical url" do
        file = create(:product_file, link: @product, display_name: "Old")

        put @action, params: @params.merge(files: [{ id: file.external_id, display_name: "New" }]), as: :json

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("canonical url")
        expect(file.reload.display_name).to eq("Old")
      end

      it "rejects client-supplied modified flag on files[] entries" do
        existing_file = create(:product_file, link: @product, display_name: "Old")

        put @action, params: @params.merge(files: [
                                             { id: existing_file.external_id, url: existing_file.url, modified: "false", display_name: "New" }
                                           ]), as: :json

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("modified")
        expect(existing_file.reload.display_name).to eq("Old")
      end

      it "preserves existing subtitle tracks when id-only files[] entry keeps a video file unchanged" do
        video = create(:streamable_video, link: @product)
        subtitle = create(:subtitle_file, product_file: video)

        put @action, params: @params.merge(files: [{ id: video.external_id }]), as: :json

        expect(response.parsed_body["success"]).to be(true)
        expect(video.reload.alive?).to be(true)
        expect(subtitle.reload.alive?).to be(true)
      end

      it "fails requests that reference a file deleted concurrently instead of resurrecting it" do
        file = create(:product_file, link: @product)
        original_external_id = file.external_id

        stubbed_once = false
        allow_any_instance_of(Link).to receive(:assign_attributes).and_wrap_original do |m, *args|
          unless stubbed_once
            stubbed_once = true
            file.mark_deleted!
          end
          m.call(*args)
        end

        put @action, params: @params.merge(files: [{ id: original_external_id }]), as: :json

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("no longer exist")
        expect(ProductFile.where(link: @product).count).to eq(1)
      end

      it "supports round-tripping serialized file entries back through PUT using id only" do
        file = create(:product_file, link: @product, display_name: "Round Trip")
        serialized_files = JSON.parse(@product.as_json(api_scopes: ["view_public", "edit_products"]).to_json)["files"]
        expect(serialized_files.first["id"]).to eq(file.external_id)

        put @action, params: @params.merge(
          files: serialized_files.map { |f| { id: f["id"] } }
        ), as: :json

        expect(response.parsed_body["success"]).to be(true)
        expect(file.reload.alive?).to be(true)
        expect(file.display_name).to eq("Round Trip")
      end

      it "reorders covers via cover_ids" do
        preview1 = AssetPreview.new(link: @product)
        preview1.file.attach(fixture_file_upload("smilie.png", "image/png"))
        preview1.save!
        preview2 = AssetPreview.new(link: @product)
        preview2.file.attach(fixture_file_upload("smilie.png", "image/png"))
        preview2.save!

        put @action, params: @params.merge(cover_ids: [preview2.guid, preview1.guid])
        expect(response.parsed_body["success"]).to be(true)
        @product.reload
        expect(@product.display_asset_previews.map(&:guid)).to eq([preview2.guid, preview1.guid])
      end

      it "runs SavePostPurchaseCustomFieldsService after rich content changes" do
        expect_any_instance_of(Product::SavePostPurchaseCustomFieldsService).to receive(:perform).and_call_original
        put @action, params: @params.merge(rich_content: [
                                             { title: "Page", description: { type: "doc", content: [{ type: "shortAnswer", attrs: { label: "Your name" } }] } }
                                           ])
        expect(response.parsed_body["success"]).to be(true)
      end

      it "recomputes is_licensed after rich content changes" do
        @product.update!(is_licensed: false)
        put @action, params: @params.merge(rich_content: [
                                             { title: "Page", description: { type: "doc", content: [{ type: "licenseKey" }] } }
                                           ])
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.is_licensed).to be(true)
      end

      it "returns the updated product in the response" do
        put @action, params: @params.merge(name: "Response Check")
        body = response.parsed_body
        expect(body["success"]).to be(true)
        expect(body["product"]).to be_present
        expect(body["product"]["name"]).to eq("Response Check")
      end

      it "updates has_same_rich_content_for_all_variants to false" do
        @product.update!(has_same_rich_content_for_all_variants: true)
        put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.has_same_rich_content_for_all_variants?).to eq false
      end

      it "updates has_same_rich_content_for_all_variants to true" do
        @product.update!(has_same_rich_content_for_all_variants: false)
        put @action, params: @params.merge(has_same_rich_content_for_all_variants: true)
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.has_same_rich_content_for_all_variants?).to eq true
      end

      it "does not trigger content migration when has_same_rich_content_for_all_variants is sent unchanged alongside other flag changes" do
        variant_category = create(:variant_category, link: @product)
        variant = create(:variant, variant_category: variant_category)
        @product.update!(has_same_rich_content_for_all_variants: false)
        variant_rc = create(:rich_content, entity: variant, title: "Variant Page", description: [], position: 0)

        put @action, params: @params.merge(has_same_rich_content_for_all_variants: false, is_adult: true)
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.is_adult).to eq true
        expect(variant_rc.reload).to be_alive
      end

      it "recomputes is_licensed when has_same_rich_content_for_all_variants changes" do
        variant_category = create(:variant_category, link: @product)
        variant = create(:variant, variant_category: variant_category)
        create(:rich_content, entity: variant, description: [{ "type" => "licenseKey" }], position: 0)
        @product.update!(has_same_rich_content_for_all_variants: true, is_licensed: false)

        put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
        expect(response.parsed_body["success"]).to be(true)
        expect(@product.reload.is_licensed).to eq true
      end

      it "runs SavePostPurchaseCustomFieldsService when has_same_rich_content_for_all_variants changes" do
        expect_any_instance_of(Product::SavePostPurchaseCustomFieldsService).to receive(:perform)
        put @action, params: @params.merge(has_same_rich_content_for_all_variants: true)
      end

      it "regenerates product file archives when has_same_rich_content_for_all_variants changes" do
        @product.update!(has_same_rich_content_for_all_variants: true)
        expect_any_instance_of(Link).to receive(:generate_product_files_archives!)
        put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
      end

      describe "content migration when toggling has_same_rich_content_for_all_variants" do
        let(:variant_category) { create(:variant_category, link: @product) }
        let(:variant1) { create(:variant, variant_category: variant_category, name: "Tier 1") }
        let(:variant2) { create(:variant, variant_category: variant_category, name: "Tier 2") }

        it "copies single variant content to product when switching to shared (true)" do
          variant1
          variant2
          @product.update!(has_same_rich_content_for_all_variants: false)
          create(:rich_content, entity: variant1, title: "Variant Page", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "From variant" }] }], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: true)
          expect(response.parsed_body["success"]).to be(true)
          @product.reload
          expect(@product.alive_rich_contents.count).to eq 1
          expect(@product.alive_rich_contents.first.title).to eq "Variant Page"
          expect(variant1.reload.alive_rich_contents.count).to eq 0
          expect(variant2.reload.alive_rich_contents.count).to eq 0
        end

        it "rejects switching to shared when multiple variants have distinct content" do
          variant1
          variant2
          @product.update!(has_same_rich_content_for_all_variants: false)
          create(:rich_content, entity: variant1, title: "V1 Page", description: [], position: 0)
          create(:rich_content, entity: variant2, title: "V2 Page", description: [], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: true)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include("multiple variants have distinct content")
          expect(@product.reload.has_same_rich_content_for_all_variants?).to eq false
        end

        it "allows switching back to shared when all variants have identical content (round-trip)" do
          variant1
          variant2
          @product.update!(has_same_rich_content_for_all_variants: true)
          create(:rich_content, entity: @product, title: "Shared Page", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
          expect(response.parsed_body["success"]).to be(true)
          expect(variant1.reload.alive_rich_contents.count).to eq 1
          expect(variant2.reload.alive_rich_contents.count).to eq 1

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: true)
          expect(response.parsed_body["success"]).to be(true)
          @product.reload
          expect(@product.has_same_rich_content_for_all_variants?).to eq true
          expect(@product.alive_rich_contents.count).to eq 1
          expect(@product.alive_rich_contents.first.title).to eq "Shared Page"
          expect(variant1.reload.alive_rich_contents.count).to eq 0
          expect(variant2.reload.alive_rich_contents.count).to eq 0
        end

        it "rejects switching to shared when both product and variant content exist" do
          variant1
          @product.update!(has_same_rich_content_for_all_variants: false)
          create(:rich_content, entity: @product, title: "Product Page", description: [], position: 0)
          create(:rich_content, entity: variant1, title: "Variant Page", description: [], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: true)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include("both product-level and variant-level content exist")
          expect(@product.reload.has_same_rich_content_for_all_variants?).to eq false
        end

        it "copies product content to all variants when switching to per-variant (false)" do
          variant1
          variant2
          @product.update!(has_same_rich_content_for_all_variants: true)
          create(:rich_content, entity: @product, title: "Shared Page", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Shared" }] }], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
          expect(response.parsed_body["success"]).to be(true)
          @product.reload
          expect(@product.alive_rich_contents.count).to eq 0
          expect(variant1.reload.alive_rich_contents.count).to eq 1
          expect(variant1.alive_rich_contents.first.title).to eq "Shared Page"
          expect(variant2.reload.alive_rich_contents.count).to eq 1
          expect(variant2.alive_rich_contents.first.title).to eq "Shared Page"
        end

        it "rejects switching to per-variant when product has no variants" do
          @product.update!(has_same_rich_content_for_all_variants: true)
          existing_rc = create(:rich_content, entity: @product, title: "Shared Page", description: [], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include("no variants")
          expect(@product.reload.has_same_rich_content_for_all_variants?).to eq true
          expect(existing_rc.reload).to be_alive
        end

        it "rebinds variant.product_files from migrated file embeds when switching to per-variant" do
          variant1
          product_file = create(:product_file, link: @product)
          Aws::S3::Resource.new.bucket(S3_BUCKET).object(product_file.s3_key).put(body: "test content")
          @product.update!(has_same_rich_content_for_all_variants: true)
          create(:rich_content, entity: @product, title: "Page with file", description: [
                   { "type" => "fileEmbed", "attrs" => { "id" => product_file.external_id, "uid" => SecureRandom.uuid } }
                 ], position: 0)

          put @action, params: @params.merge(has_same_rich_content_for_all_variants: false)
          expect(response.parsed_body["success"]).to be(true)
          expect(variant1.reload.product_files).to include(product_file)
        end

        it "clears variant pages and writes replacement when switching to shared with rich_content" do
          variant1
          @product.update!(has_same_rich_content_for_all_variants: false)
          create(:rich_content, entity: variant1, title: "Old Variant Page", description: [], position: 0)

          put @action, params: @params.merge(
            has_same_rich_content_for_all_variants: true,
            rich_content: [{ title: "New Shared Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Replacement" }] }] } }]
          )
          expect(response.parsed_body["success"]).to be(true)
          @product.reload
          expect(@product.alive_rich_contents.count).to eq 1
          expect(@product.alive_rich_contents.first.title).to eq "New Shared Page"
          expect(variant1.reload.alive_rich_contents.count).to eq 0
        end

        it "rejects switching to per-variant with rich_content in the same request" do
          variant1
          @product.update!(has_same_rich_content_for_all_variants: true)
          existing_rc = create(:rich_content, entity: @product, title: "Old Shared Page", description: [], position: 0)

          put @action, params: @params.merge(
            has_same_rich_content_for_all_variants: false,
            rich_content: [{ title: "New Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Replacement" }] }] } }]
          )
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include("per-variant mode")
          expect(@product.reload.has_same_rich_content_for_all_variants?).to eq true
          expect(existing_rc.reload).to be_alive
        end

        it "rejects product-level rich_content when already in per-variant mode" do
          variant1
          @product.update!(has_same_rich_content_for_all_variants: false)

          put @action, params: @params.merge(
            rich_content: [{ title: "Product Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "test" }] }] } }]
          )
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include("per-variant mode")
        end

        it "allows product-level rich_content when flag is false but no variants exist" do
          @product.update!(has_same_rich_content_for_all_variants: false)

          put @action, params: @params.merge(
            rich_content: [{ title: "Product Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "test" }] }] } }]
          )
          expect(response.parsed_body["success"]).to be(true)
          expect(@product.reload.alive_rich_contents.count).to eq 1
        end
      end

      it "rejects non-array tags" do
        put @action, params: @params.merge(tags: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("tags must be an array")
      end

      it "rejects tags with non-string elements" do
        put @action, params: @params.merge(tags: ["valid", { nested: "hash" }])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("tags must be an array of strings")
      end

      it "rejects non-array rich_content" do
        put @action, params: @params.merge(rich_content: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array")
      end

      it "rejects rich_content with non-object elements" do
        put @action, params: @params.merge(rich_content: ["not_an_object"])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("rich_content must be an array of content page objects")
      end

      it "rejects non-array files" do
        put @action, params: @params.merge(files: "oops")

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array")
      end

      it "rejects files with non-object elements" do
        put @action, params: @params.merge(files: ["not_an_object"])

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be false
        expect(response.parsed_body["message"]).to include("files must be an array of file objects")
      end
    end
  end

  describe "PUT 'disable'" do
    before do
      @product = create(:product, user: @user, description: "des1")

      @action = :disable
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        put @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          product: @product.reload
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "disables a product" do
        put @action, params: @params
        expect(@product.reload.purchase_disabled_at).to_not be(nil)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(@product.reload.as_json(api_scopes: ["edit_products"]))
      end
    end
  end

  describe "PUT 'enable'" do
    before do
      @product = create(:physical_product, user: @user, description: "des1")
      @action = :enable
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        put @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          product: @product.reload
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "enables a product" do
        put @action, params: @params
        expect(@product.reload.purchase_disabled_at).to be(nil)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(@product.reload.as_json(api_scopes: ["edit_products"]))
      end
    end

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "does not publish a product if it violates existing universal offer_codes" do
        offer_code = create(:universal_offer_code, user: @user, amount_cents: 100)
        offer_code.update_column(:amount_cents, 50) # bypassing validation.

        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: false,
          message: "An existing discount code puts the price of this product below the $0.99 minimum after discount."
        }.as_json)
      end

      it "enables a link" do
        put @action, params: @params
        expect(@product.reload.purchase_disabled_at).to be_nil
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["product"]).to eq(@product.reload.as_json(api_scopes: ["edit_products"]))
      end

      context "when new account and no valid merchant account connected" do
        before do
          @user.check_merchant_account_is_linked = true
          @user.payment_address = nil
          @user.save!

          @product.update!(purchase_disabled_at: 1.day.ago)
        end

        it "does not publish the product" do
          put @action, params: @params

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to eq("You must connect at least one payment method before you can publish this product for sale.")

          expect(@product.purchase_disabled_at).to_not be_nil
        end
      end

      context "when an unknown exception is raised" do
        before do
          @product.update!(purchase_disabled_at: 1.day.ago)

          allow_any_instance_of(Link).to receive(:publish!).and_raise("error")
        end

        it "notifies error tracker" do
          expect(ErrorNotifier).to receive(:notify).once

          put @action, params: @params
        end

        it "returns an error message" do
          put @action, params: @params

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
        end

        it "does not publish the link" do
          put @action, params: @params

          expect(@product.purchase_disabled_at).to_not be_nil
        end
      end

      context "when a variant category has no alive variants" do
        before do
          @product.update!(purchase_disabled_at: 1.day.ago)
          category = create(:variant_category, link: @product)
          variant = create(:variant, variant_category: category)
          variant.update!(deleted_at: Time.current)
        end

        it "returns a validation error instead of notifying error tracker" do
          expect(ErrorNotifier).not_to receive(:notify)

          put @action, params: @params

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to include("product versions must have at least one option")
        end
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @product = create(:product, user: @user, description: "des1")
      @action = :destroy
      @params = { id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns the right response" do
        delete @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          message: "The product was deleted successfully."
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "deletes a product" do
        delete @action, params: @params
        expect(@product.reload.deleted_at).to_not be(nil)
        expect(response.parsed_body["success"]).to be(true)
      end

      it "tells you if a product can't be found" do
        delete @action, params: { id: "NOT_REAL_TOKEN", access_token: @token.token }
        expect(response.parsed_body["success"]).to be(false)
      end
    end
  end
end
