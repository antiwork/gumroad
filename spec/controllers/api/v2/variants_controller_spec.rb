# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::VariantsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @action = :index
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with view_public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns error for nonexistent variant_category_id" do
        get @action, params: @params.merge(variant_category_id: "nonexistent")
        expect(response.parsed_body).to eq({
                                             "success" => false,
                                             "message" => "The variant_category was not found."
                                           })
      end

      it "shows the 0 variants in that variant category" do
        get @action, params: @params
        expect(response.parsed_body["variants"]).to eq []
      end

      it "shows the 1 variant in that variant category" do
        variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variants: [variant]
        }.as_json(api_scopes: ["view_public"]))
      end
    end

    it "grants access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get @action, params: @params.merge(access_token: token.token)
      expect(response).to be_successful
    end
  end

  describe "POST 'create'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")

      @action = :create
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        name: "blue",
        price_difference_cents: 100
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "returns error for nonexistent variant_category_id" do
        post @action, params: @params.merge(variant_category_id: "nonexistent")
        expect(response.parsed_body).to eq({
                                             "success" => false,
                                             "message" => "The variant_category was not found."
                                           })
      end

      describe "usd" do
        it "works if variants passed in" do
          post :create, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end

        it "returns the right response" do
          post @action, params: @params
          variant = @product.variant_categories.first.variants.first
          variant_json = variant.as_json
          variant_json["rich_content"] = variant.rich_content_json
          expect(response.parsed_body).to eq({
            success: true,
            variant: variant_json
          }.as_json)
        end
      end

      describe "yen" do
        before do
          @user = create(:user, currency_type: "jpy")
          @product = create(:product, price_currency_type: "jpy", user: @user, description: "des", created_at: Time.current)
          @variant_category = create(:variant_category, link: @product, title: "colors")
          @params = {
            link_id: @product.external_id,
            variant_category_id: @variant_category.external_id,
            name: "blue",
            price_difference_cents: 100
          }
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

        it "works if variants passed in" do
          post :create, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end
      end
    end
  end

  describe "GET 'show'" do
    before do
      @user = create(:user)
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)

      @action = :show
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        id: @variant.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with view_public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        get @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The variant was not found."
        }.as_json)
      end

      it "returns error for nonexistent variant_category_id" do
        get @action, params: @params.merge(variant_category_id: "nonexistent")
        expect(response.parsed_body).to eq({
                                             "success" => false,
                                             "message" => "The variant_category was not found."
                                           })
      end

      it "returns the right response" do
        get @action, params: @params
        variant = @product.variant_categories.first.variants.first
        variant_json = variant.as_json
        variant_json["rich_content"] = variant.rich_content_json
        expect(response.parsed_body).to eq({
          success: true,
          variant: variant_json
        }.as_json)
      end

      it "shows the variant in that variant category" do
        get @action, params: @params
        variant = @product.variant_categories.first.variants.first
        expected = variant.as_json(api_scopes: ["view_public"])
        expected["rich_content"] = variant.rich_content_json
        expect(response.parsed_body["variant"]).to eq(expected.as_json)
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)

      @action = :update
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        id: @variant.external_id,
        name: "blue",
        price_difference_cents: 100
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      describe "usd" do
        it "works if variants passed in" do
          put @action, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end

        it "returns the right response" do
          put @action, params: @params
          variant_json = @variant.reload.as_json
          variant_json["rich_content"] = @variant.rich_content_json
          expect(response.parsed_body).to eq({
            success: true,
            variant: variant_json
          }.as_json)
        end

        it "returns rich_content in response" do
          put @action, params: @params
          expect(response.parsed_body["variant"]).to have_key("rich_content")
        end

        it "fails gracefully on bad id" do
          put @action, params: @params.merge(id: @params[:id] + "++")
          expect(response.parsed_body).to eq({
            success: false,
            message: "The variant was not found."
          }.as_json)
        end

        it "returns error for nonexistent variant_category_id" do
          put @action, params: @params.merge(variant_category_id: "nonexistent")
          expect(response.parsed_body).to eq({
                                               "success" => false,
                                               "message" => "The variant_category was not found."
                                             })
        end
      end

      describe "rich content" do
        it "rejects variant rich content updates when shared-content mode is enabled" do
          @product.update!(has_same_rich_content_for_all_variants: true)
          put @action, params: @params.merge(
            rich_content: [
              { title: "Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "test" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["message"]).to include("shared content for all variants")
          expect(@variant.reload.alive_rich_contents.count).to eq 0
        end

        it "returns error for malformed JSON rich_content" do
          put @action, params: @params.merge(rich_content: "{invalid json")
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["message"]).to include("Invalid JSON")
        end

        it "handles blank-string rich_content as empty array" do
          create(:rich_content, entity: @variant, title: "Page 1", description: [], position: 0)
          @product.update!(has_same_rich_content_for_all_variants: false)
          put @action, params: @params.merge(rich_content: "")
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          expect(@variant.alive_rich_contents.count).to eq 0
        end

        it "updates variant with rich content pages" do
          put @action, params: @params.merge(
            rich_content: [
              { title: "Getting Started", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Welcome!" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          expect(@variant.alive_rich_contents.count).to eq 1
          expect(@variant.alive_rich_contents.first.title).to eq "Getting Started"
          expect(@variant.alive_rich_contents.first.description).to eq [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Welcome!" }] }]
        end

        it "replaces existing variant rich content" do
          existing_rc = create(:rich_content, entity: @variant, title: "Old Page", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Old" }] }], position: 0)
          put @action, params: @params.merge(
            rich_content: [
              { title: "New Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "New" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          expect(@variant.alive_rich_contents.count).to eq 1
          expect(@variant.alive_rich_contents.first.title).to eq "New Page"
          expect(existing_rc.reload).to be_deleted
        end

        it "updates existing rich content page by id" do
          existing_rc = create(:rich_content, entity: @variant, title: "Page 1", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Original" }] }], position: 0)
          put @action, params: @params.merge(
            rich_content: [
              { id: existing_rc.external_id, title: "Updated Page 1", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Updated" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          existing_rc.reload
          expect(existing_rc.title).to eq "Updated Page 1"
          expect(existing_rc.description).to eq [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Updated" }] }]
        end

        it "deletes all pages when empty array is sent as JSON body" do
          create(:rich_content, entity: @variant, title: "Page 1", description: [], position: 0)
          put @action, params: @params.merge(rich_content: []), as: :json
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          expect(@variant.alive_rich_contents.count).to eq 0
        end

        it "deletes all pages when empty array is sent as JSON string" do
          create(:rich_content, entity: @variant, title: "Page 1", description: [], position: 0)
          put @action, params: @params.merge(rich_content: "[]")
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          expect(@variant.alive_rich_contents.count).to eq 0
        end

        it "does not include deleted pages in response after replacement" do
          create(:rich_content, entity: @variant, title: "Old Page", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Old" }] }], position: 0)
          put @action, params: @params.merge(
            rich_content: [
              { title: "New Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "New" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          rich_content = response.parsed_body["variant"]["rich_content"]
          expect(rich_content.length).to eq 1
          expect(rich_content.first["title"]).to eq "New Page"
        end

        it "returns rich_content in response after update" do
          put @action, params: @params.merge(
            rich_content: [
              { title: "Content Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Hello" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          rich_content = response.parsed_body["variant"]["rich_content"]
          expect(rich_content.length).to eq 1
          expect(rich_content.first["title"]).to eq "Content Page"
          expect(rich_content.first["description"]).to eq({ "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }] })
        end

        it "does not touch rich content when rich_content param is not provided" do
          existing_rc = create(:rich_content, entity: @variant, title: "Keep Me", description: [], position: 0)
          put @action, params: @params
          expect(response.parsed_body["success"]).to eq true
          expect(existing_rc.reload).to be_alive
        end

        it "processes upsellCard nodes via SaveContentUpsellsService" do
          upsell_product = create(:product, user: @user)
          put @action, params: @params.merge(
            rich_content: [
              {
                title: "Page with upsell",
                description: { type: "doc", content: [
                  { type: "upsellCard", attrs: { productId: upsell_product.external_id } }
                ] }
              }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          description = @variant.alive_rich_contents.first.description
          upsell_node = description.find { |n| n["type"] == "upsellCard" }
          expect(upsell_node.dig("attrs", "id")).to be_present
        end

        it "wires up variant.product_files from file embeds" do
          product_file = create(:product_file, link: @product)
          Aws::S3::Resource.new.bucket(S3_BUCKET).object(product_file.s3_key).put(body: "test content")
          put @action, params: @params.merge(
            rich_content: [
              {
                title: "Page with file",
                description: { type: "doc", content: [
                  { type: "fileEmbed", attrs: { id: product_file.external_id, uid: SecureRandom.uuid } }
                ] }
              }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          @variant.reload
          expect(@variant.product_files).to include(product_file)
        end

        it "rejects file embeds referencing files from another product" do
          other_product = create(:product, user: @user)
          foreign_file = create(:product_file, link: other_product)
          put @action, params: @params.merge(
            rich_content: [
              {
                title: "Page with foreign file",
                description: { type: "doc", content: [
                  { type: "fileEmbed", attrs: { id: foreign_file.external_id, uid: SecureRandom.uuid } }
                ] }
              }
            ]
          )
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["message"]).to include("not belonging to this product")
        end

        it "rejects file embeds referencing deleted files" do
          deleted_file = create(:product_file, link: @product)
          deleted_file.mark_deleted!
          put @action, params: @params.merge(
            rich_content: [
              {
                title: "Page with deleted file",
                description: { type: "doc", content: [
                  { type: "fileEmbed", attrs: { id: deleted_file.external_id, uid: SecureRandom.uuid } }
                ] }
              }
            ]
          )
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["message"]).to include("not belonging to this product")
        end

        it "sets product.is_licensed when licenseKey node is added" do
          @product.update!(is_licensed: false)
          put @action, params: @params.merge(
            rich_content: [
              {
                title: "License Page",
                description: { type: "doc", content: [
                  { type: "licenseKey" }
                ] }
              }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          expect(@product.reload.is_licensed).to eq true
        end

        it "clears product.is_licensed and is_multiseat_license when last licenseKey is removed" do
          create(:rich_content, entity: @variant, description: [{ "type" => "licenseKey" }], position: 0)
          @product.update!(is_licensed: true, is_multiseat_license: true, has_same_rich_content_for_all_variants: false)
          put @action, params: @params.merge(
            rich_content: [
              { title: "No License", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "No license" }] }] } }
            ]
          )
          expect(response.parsed_body["success"]).to eq true
          @product.reload
          expect(@product.is_licensed).to eq false
          expect(@product.is_multiseat_license).to eq false
        end

        it "runs SavePostPurchaseCustomFieldsService after rich content changes" do
          expect_any_instance_of(Product::SavePostPurchaseCustomFieldsService).to receive(:perform)
          put @action, params: @params.merge(
            rich_content: [
              { title: "Page", description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "test" }] }] } }
            ]
          )
        end
      end

      describe "yen" do
        before do
          @user = create(:user, currency_type: "jpy")
          @product = create(:product, price_currency_type: "jpy", user: @user, description: "des", created_at: Time.current)
          @variant_category = create(:variant_category, link: @product, title: "colors")
          @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)
          @params = {
            link_id: @product.external_id,
            variant_category_id: @variant_category.external_id,
            id: @variant.external_id,
            name: "blue",
            price_difference_cents: 100
          }
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
          @params.merge!(access_token: @token.token)
        end

        it "works if variants passed in" do
          put @action, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 1
          expect(@product.variant_categories.first.variants.alive.first.name).to eq "blue"
          expect(@product.variant_categories.first.variants.alive.first.price_difference_cents).to eq 100
        end
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product, title: "colors")
      @variant = create(:variant, variant_category: @variant_category, name: "red", price_difference_cents: 69)

      @action = :destroy
      @params = {
        link_id: @product.external_id,
        variant_category_id: @variant_category.external_id,
        id: @variant.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        delete @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The variant was not found."
        }.as_json)
      end

      it "returns error for nonexistent variant_category_id" do
        delete @action, params: @params.merge(variant_category_id: "nonexistent")
        expect(response.parsed_body).to eq({
                                             "success" => false,
                                             "message" => "The variant_category was not found."
                                           })
      end

      describe "usd" do
        it "works if variants passed in" do
          delete @action, params: @params
          expect(@product.reload.variant_categories.count).to eq 1
          expect(@product.variant_categories.first.title).to eq "colors"
          expect(@product.variant_categories.first.variants.alive.count).to eq 0
        end

        it "returns the right response" do
          delete @action, params: @params
          expect(response.parsed_body).to eq({
            success: true,
            message: "The variant was deleted successfully."
          }.as_json(api_scopes: ["edit_products"]))
        end

        # This endpoint deletes a single version outside the product editor's
        # deletion guards, so it is audited (ProductVariantDeletionAudit,
        # gumroad-private#1379). It is easy to miss when auditing deletion paths
        # because it sets `deleted_at` directly rather than via `mark_deleted`.
        describe "deletion audit" do
          it "records the deletion with an explicit-destroy intent" do
            expect { delete @action, params: @params }
              .to change { ProductVariantDeletionAudit.count }.by(1)

            audit = ProductVariantDeletionAudit.last
            expect(audit.route).to eq(ProductVariantDeletionAudit::API_V2_VARIANT_DESTROY)
            expect(audit.intent_source).to eq(ProductVariantDeletionAudit::API_EXPLICIT_DESTROY)
            expect(audit.product_id).to eq(@product.id)
            expect(audit.actor_user_id).to eq(@user.id)
            expect(audit.deleted_variant_external_ids).to eq([@variant.external_id])
            expect(audit.deleted_variant_count).to eq(1)
          end

          # A second DELETE deletes nothing, so it is not a deletion this request
          # performed and must not add a row. The row is locked and `deleted_at`
          # re-read under the lock, precisely so two overlapping requests cannot
          # both record the same deletion.
          it "does not record a second audit when the variant was already deleted" do
            expect { delete @action, params: @params }
              .to change { ProductVariantDeletionAudit.count }.by(1)

            expect { delete @action, params: @params }
              .not_to change { ProductVariantDeletionAudit.count }
          end

          # Regression: an earlier version of this used `update_all` to make the
          # transition atomic, which silently skipped BaseVariant's after_commit
          # callbacks and would have left stale product caches and stale search
          # state. Assert on the observable effects of those callbacks rather than
          # on the instance, since the controller loads its own via the
          # variant_category association.

          # Correlation logging used to run inside the deletion's transaction,
          # where a raising logger propagated out of with_lock and rolled the
          # deletion back. It now runs in after_commit, after the row is written,
          # so a raise could only 500 a delete that had already succeeded. Either
          # way it must cost the log line and nothing more.
          it "is not broken by a failing correlation logger" do
            allow(AuditCorrelationId).to receive(:log_pair).and_raise(IOError, "log device full")

            expect { delete @action, params: @params }
              .to change { ProductVariantDeletionAudit.count }.by(1)

            expect(response.parsed_body["success"]).to be(true)
            expect(@variant.reload).to be_deleted
          end

          # Asserted on the call rather than on Rails.logger output: the write is
          # deferred to after_commit and lands after the stub's window, and
          # ActionDispatch::RequestId is middleware that controller specs bypass, so
          # request_id is nil here. The end-to-end version with a real request id is
          # in test/integration/product_variant_deletion_audit_request_id_test.rb.
          it "logs a correlation pair carrying the stored digest" do
            logged = []
            allow(AuditCorrelationId).to receive(:log_pair) { |**kwargs| logged << kwargs; true }

            delete @action, params: @params

            expect(logged.size).to eq(1)
            expect(logged.first[:correlation_id]).to eq(ProductVariantDeletionAudit.last.correlation_id)
          end

          it "still invalidates the product cache and updates the search index" do
            expect_any_instance_of(Link).to receive(:invalidate_cache).at_least(:once)
            expect_any_instance_of(BaseVariant).to receive(:update_product_search_index).at_least(:once).and_call_original

            delete @action, params: @params

            expect(@variant.reload).to be_deleted
          end
        end
      end
    end
  end
end
