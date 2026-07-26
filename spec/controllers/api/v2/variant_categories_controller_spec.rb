# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::VariantCategoriesController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @action = :index
      @params = { link_id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with view_public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "shows the 0 variant categories" do
        get @action, params: @params
        expect(response.parsed_body["variant_categories"]).to be_empty
      end

      it "shows the 1 variant category" do
        variant_category = create(:variant_category, link: @product)
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variant_categories: [variant_category]
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
      @product = create(:product, user: @user, description: "des", price_cents: 10_000, created_at: Time.current)
      @new_variant_category_params = { title: "hi" }
      @action = :create
      @params = { link_id: @product.external_id }.merge @new_variant_category_params
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "works if a new variant_category is passed in" do
        post @action, params: @params
        expect(@product.reload.variant_categories.alive.count).to eq(1)
        expect(@product.variant_categories.alive.first.title).to eq(@new_variant_category_params[:title])
      end

      it "returns the right response" do
        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variant_category: @product.variant_categories.alive.first
        }.as_json(api_scopes: ["edit_products"]))
      end

      describe "there is already an offer code" do
        before do
          @first_variant_category = create(:variant_category, link: @product)
        end

        it "works if a new variant_category is passed in" do
          post @action, params: @params
          expect(@product.reload.variant_categories.alive.count).to eq(2)
          expect(@product.variant_categories.alive.first.title).to eq(@first_variant_category[:title])
          expect(@product.variant_categories.alive.second.title).to eq(@new_variant_category_params[:title])
        end
      end
    end
  end

  describe "GET 'show'" do
    before do
      @product = create(:product, user: @user, description: "des", created_at: Time.current)
      @variant_category = create(:variant_category, link: @product)
      @action = :show
      @params = { link_id: @product.external_id, id: @variant_category.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        post @action, params: @params.merge(id: @variant_category.external_id + "++")
        expect(response.parsed_body).to eq({
          message: "The variant_category was not found.",
          success: false
        }.as_json)
      end

      it "returns the right response" do
        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variant_category: @product.reload.variant_categories.alive.first
        }.as_json(api_scopes: ["view_public"]))
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @product = create(:product, user: @user, description: "des", price_cents: 10_000, created_at: Time.current)
      @variant_category = create(:variant_category, title: "name1", link: @product)
      @new_variant_category_params = { title: "new_name1" }

      @action = :update
      @params = {
        link_id: @product.external_id,
        id: @variant_category.external_id
      }.merge @new_variant_category_params
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        post @action, params: @params.merge(id: @variant_category.external_id + "++")
        expect(response.parsed_body).to eq({
          message: "The variant_category was not found.",
          success: false
        }.as_json)
      end

      it "updates the variant category" do
        put @action, params: @params
        expect(@product.reload.variant_categories.alive.count).to eq(1)
        expect(@product.variant_categories.alive.first.title).to eq(@new_variant_category_params[:title])
      end

      it "returns the right response" do
        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          variant_category: @product.reload.variant_categories.alive.first
        }.as_json(api_scopes: ["edit_products"]))
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @product = create(:product, user: @user, description: "des", price_cents: 10_000, created_at: Time.current)
      @variant_category = create(:variant_category, link: @product)
      @action = :destroy
      @params = {
        link_id: @product.external_id,
        id: @variant_category.external_id
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
        post @action, params: @params.merge(id: @variant_category.external_id + "++")
        expect(response.parsed_body).to eq({
          message: "The variant_category was not found.",
          success: false
        }.as_json)
      end

      it "works if variant category id is passed" do
        delete @action, params: @params
        expect(@product.reload.variant_categories.alive.count).to eq(0)
      end

      it "returns the right response" do
        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          message: "The variant_category was deleted successfully."
        }.as_json(api_scopes: ["edit_products"]))
      end

      # This endpoint is an explicit destructive call that deliberately sits
      # outside the product editor's deletion guards. It is audited so the
      # deletion is at least visible after the fact
      # (ProductVariantDeletionAudit, gumroad-private#1379).
      describe "deletion audit" do
        it "records the deletion with an explicit-destroy intent" do
          expect { delete @action, params: @params }
            .to change { ProductVariantDeletionAudit.count }.by(1)

          audit = ProductVariantDeletionAudit.last
          expect(audit.route).to eq(ProductVariantDeletionAudit::API_V2_VARIANT_CATEGORY_DESTROY)
          expect(audit.intent_source).to eq(ProductVariantDeletionAudit::API_EXPLICIT_DESTROY)
          expect(audit.product_id).to eq(@product.id)
          expect(audit.actor_user_id).to eq(@user.id)
          expect(audit.deleted_variant_category_external_ids).to eq([@variant_category.external_id])
        end

        # `VariantCategory#mark_deleted` does not cascade — `has_many :variants`
        # carries no `dependent:` option — so this endpoint can leave live
        # versions parented to a deleted grouping. The count makes that
        # observable instead of something you have to know to look for.
        it "records how many child variants were left alive" do
          create(:variant, variant_category: @variant_category)
          create(:variant, variant_category: @variant_category)

          delete @action, params: @params

          expect(ProductVariantDeletionAudit.last.alive_child_variant_count).to eq(2)
        end

        # A second DELETE on an already-deleted grouping deletes nothing, so it is
        # not a successful deletion and must not add a row. Otherwise a retrying
        # or looping client inflates the trail with events that never happened.
        # Regression: an earlier version used `update_all` to make the transition
        # atomic, which silently skipped VariantCategory's
        # `after_commit :invalidate_product_cache` and would have left stale
        # product caches.
        it "still invalidates the product cache" do
          expect_any_instance_of(Link).to receive(:invalidate_cache).at_least(:once)

          delete @action, params: @params

          expect(@variant_category.reload).to be_deleted
        end

        it "does not record a second audit when nothing was left to delete" do
          expect { delete @action, params: @params }
            .to change { ProductVariantDeletionAudit.count }.by(1)

          expect { delete @action, params: @params }
            .not_to change { ProductVariantDeletionAudit.count }
        end

        # Rails accepts X-Request-Id from the client and only strips punctuation,
        # so the raw value is caller-controlled and must never be persisted. The
        # end-to-end proof lives in
        # test/integration/product_variant_deletion_audit_request_id_test.rb —
        # ActionDispatch::RequestId is middleware, which controller specs bypass
        # (request_id is nil here), so this asserts the controller runs the value
        # through the digest helper rather than storing it directly.
        it "digests the request id instead of storing it verbatim" do
          hostile = "b" * 255
          allow(AuditCorrelationId).to receive(:for).and_call_original
          allow_any_instance_of(ActionDispatch::Request).to receive(:request_id).and_return(hostile)

          delete @action, params: @params

          correlation_id = ProductVariantDeletionAudit.last.correlation_id
          expect(AuditCorrelationId).to have_received(:for).with(hostile).at_least(:once)
          expect(correlation_id).not_to eq(hostile)
          expect(correlation_id).to eq(AuditCorrelationId.for(hostile))
          expect(correlation_id).to match(/\A[0-9a-f]{64}\z/)
        end
      end
    end
  end
end
