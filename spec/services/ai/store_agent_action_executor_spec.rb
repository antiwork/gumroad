# frozen_string_literal: true

require "spec_helper"

# The executor now applies a confirmed change by REPLAYING it against the real public v2 API
# in-process (StoreAgentApiClient mints a short-lived token scoped to the seller and dispatches
# through the real controllers). These specs therefore assert the end-to-end effect: a confirmed
# api_write actually mutates the seller's data, reusing the endpoint's own auth + validation, and a
# tampered/unsupported action is rejected without effect.
describe Ai::StoreAgentActionExecutor do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:executor) { described_class.new(seller:, pundit_user:) }

  def api_write(endpoint:, path_params: {}, params: {})
    { "endpoint" => endpoint, "path_params" => path_params, "params" => params }
  end

  describe "#execute" do
    context "create_offer_code (write replayed through the API)" do
      let!(:product) { create(:product, user: seller, price_cents: 1000) }

      it "creates a discount on the product" do
        result = executor.execute(
          type: "api_write",
          params: api_write(
            endpoint: "create_offer_code",
            path_params: { "link_id" => product.external_id },
            params: { "name" => "LAUNCH", "amount_off" => 20, "offer_type" => "percent" },
          ),
        )

        expect(result[:success]).to be(true)
        offer_code = product.reload.offer_codes.alive.last
        expect(offer_code.code).to eq("LAUNCH")
        expect(offer_code.amount_percentage).to eq(20)
        # The created object is returned so the chat can render it inline as a card.
        expect(result[:object]).to include(type: "discount", title: "LAUNCH")
      end
    end

    context "update_product (price change replayed through the API)" do
      let!(:product) { create(:product, user: seller, price_cents: 1000) }

      it "updates the price" do
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "update_product", path_params: { "id" => product.external_id }, params: { "price" => 2500 }),
        )

        expect(result[:success]).to be(true)
        expect(product.reload.price_cents).to eq(2500)
      end

      it "does not touch another seller's product (token is scoped to this seller)" do
        other_product = create(:product, price_cents: 1000)

        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "update_product", path_params: { "id" => other_product.external_id }, params: { "price" => 5 }),
        )

        # The seller's token can't resolve another seller's product, so the API returns not-found and
        # nothing changes.
        expect(result[:success]).to be(false)
        expect(other_product.reload.price_cents).to eq(1000)
      end
    end

    context "publish / unpublish (enable / disable replayed through the API)" do
      let!(:product) { create(:product, user: seller, purchase_disabled_at: Time.current) }

      it "publishes a product via enable_product" do
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "enable_product", path_params: { "id" => product.external_id }),
        )

        expect(result[:success]).to be(true)
        expect(product.reload.alive?).to be(true)
      end

      it "unpublishes a product via disable_product" do
        product.publish!
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "disable_product", path_params: { "id" => product.external_id }),
        )

        expect(result[:success]).to be(true)
        expect(product.reload.alive?).to be(false)
      end
    end

    context "unsupported / tampered actions" do
      it "rejects a non-api_write type without raising" do
        result = executor.execute(type: "delete_account", params: {})

        expect(result[:success]).to be(false)
        expect(result[:message]).to be_present
      end

      it "rejects an unknown endpoint id" do
        result = executor.execute(type: "api_write", params: api_write(endpoint: "drop_database"))

        expect(result[:success]).to be(false)
        expect(result[:message]).to be_present
      end

      it "rejects a READ endpoint sent as a write (reads never mutate, so never execute here)" do
        result = executor.execute(type: "api_write", params: api_write(endpoint: "list_products"))

        expect(result[:success]).to be(false)
      end

      it "fails cleanly when a required path param is missing" do
        result = executor.execute(type: "api_write", params: api_write(endpoint: "update_product", path_params: {}, params: { "price" => 5 }))

        expect(result[:success]).to be(false)
        expect(result[:message]).to match(/missing path parameter/i)
      end
    end

    context "role-scoped access (acting user is a non-owner team member)" do
      let(:seller) { create(:named_seller) }
      # A marketing member is allowed on the Agent tab but cannot refund/view payouts in the
      # dashboard. The executor must refuse those writes (defense in depth on top of the narrowed
      # token scopes) rather than replay them as the store owner.
      let(:marketing) { create(:user) }
      let(:pundit_user) { SellerContext.new(user: marketing, seller:) }
      let!(:product) { create(:product, user: seller, price_cents: 1000) }

      before { create(:team_membership, user: marketing, seller:, role: TeamMembership::ROLE_MARKETING) }

      it "lets a marketing member perform a content write (edit_products)" do
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "update_product", path_params: { "id" => product.external_id }, params: { "price" => 2500 }),
        )

        expect(result[:success]).to be(true)
        expect(product.reload.price_cents).to eq(2500)
      end

      it "refuses a refund (refund_sales) for a marketing member without mutating" do
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "refund_sale", path_params: { "id" => "sale_1" }, params: { "amount_cents" => 100 }),
        )

        expect(result[:success]).to be(false)
        expect(result[:message]).to match(/permission/i)
      end

      it "refuses resend_receipt for a marketing member (edit_sales, which marketing lacks)" do
        # resend_receipt is guarded by edit_sales on the real v2 endpoint, NOT view_sales, so a
        # marketing member (who has only view_sales) must not be able to trigger a buyer email.
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "resend_receipt", path_params: { "id" => "sale_1" }),
        )

        expect(result[:success]).to be(false)
        expect(result[:message]).to match(/permission/i)
      end

      it "refuses creating a webhook (admin-only) for a marketing member without mutating" do
        # The v2 resource_subscriptions endpoint only needs view_sales, but installing a webhook is
        # OAuth-app management — admin-only in the dashboard — so the agent gates it admin_only. A
        # marketing member must not be able to point store webhooks at an arbitrary URL.
        expect do
          result = executor.execute(
            type: "api_write",
            params: api_write(endpoint: "create_resource_subscription", params: { "resource_name" => "sale", "post_url" => "https://evil.example.com/hook" }),
          )

          expect(result[:success]).to be(false)
          expect(result[:message]).to match(/permission/i)
        end.not_to change { seller.resource_subscriptions.count }
      end

      it "refuses license management (admin-only) for a marketing member" do
        # License management is admin/support-only in the dashboard (manage_license?), and support
        # can't reach the Agent tab, so a marketing member must not rotate/disable license keys.
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "disable_license", params: { "product_id" => "p1", "license_key" => "KEY-1" }),
        )

        expect(result[:success]).to be(false)
        expect(result[:message]).to match(/permission/i)
      end

      it "refuses changing the account-level refund policy (admin-only) for a marketing member" do
        # The account-level refund policy is owner-only in the dashboard (Settings::Main), so a
        # marketing member must not change refund terms through the agent.
        result = executor.execute(
          type: "api_write",
          params: api_write(endpoint: "update_refund_policy", params: { "refund_period" => "30" }),
        )

        expect(result[:success]).to be(false)
        expect(result[:message]).to match(/permission/i)
      end
    end
  end
end
