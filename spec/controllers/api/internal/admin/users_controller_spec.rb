# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::UsersController do
  let(:admin_user) { create(:admin_user) }
  let(:user_id_required_message) { "user_id is required for mutating admin actions. Use /internal/admin/users/info to look up the user_id by email." }

  shared_examples "supports user lookup by user_id" do |action, method: :post, build_user: -> { create(:user) }, extra_params: {}, success_status: :ok|
    describe "user_id lookup" do
      it "looks up the user by user_id" do
        user = instance_exec(&build_user)
        public_send(method, action, params: extra_params.merge(user_id: user.external_id))
        expect(response).to have_http_status(success_status)
      end

      it "returns 404 when user_id does not match any user" do
        public_send(method, action, params: extra_params.merge(user_id: "999999999999"))
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
      end

      it "prefers user_id over email when both are provided" do
        target = instance_exec(&build_user)
        other = instance_exec(&build_user)
        public_send(method, action, params: extra_params.merge(user_id: target.external_id, email: other.email))
        expect(response).to have_http_status(success_status)
      end
    end
  end

  shared_examples "requires user_id for user mutation" do |action, extra_params: {}|
    it "returns 400 when only email is provided" do
      user = create(:user)

      post action, params: extra_params.merge(email: user.email)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end
  end

  shared_examples "checks expected_email for user mutation" do |action, build_user: -> { create(:user) }, extra_params: {}|
    it "rejects mismatched expected_email without mutating the user" do
      user = instance_exec(&build_user)

      post action, params: extra_params.merge(user_id: user.external_id, expected_email: "other@example.com")

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to eq({ success: false, message: "expected_email does not match the user's current email" }.as_json)
    end
  end

  describe "GET info" do
    include_examples "admin api authorization required", :get, :info

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns a bad request when email is missing" do
      get :info

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :info, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns a comprehensive info payload for a compliant seller" do
      user = create(:compliant_user,
                    email: "seller@example.com",
                    name: "Seller One",
                    username: "sellerone",
                    locale: "fr",
                    timezone: "Eastern Time (US & Canada)",
                    account_created_ip: "1.2.3.4",
                    current_sign_in_ip: nil,
                    current_sign_in_at: nil,
                    last_sign_in_ip: nil,
                    last_sign_in_at: nil)

      get :info, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)

      info = response.parsed_body["user"]
      expect(info).to include(
        "id" => user.external_id,
        "email" => user.form_email,
        "name" => "Seller One",
        "username" => "sellerone",
        "deleted_at" => nil,
        "locale" => "fr",
        "timezone" => "Eastern Time (US & Canada)",
        "active_watched_user" => nil,
        "two_factor_authentication_enabled" => false
      )
      expect(info["created_at"]).to eq(user.created_at.as_json)
      expect(info["sign_in"]).to eq(
        "account_created_ip" => "1.2.3.4",
        "current_ip" => nil,
        "current_at" => nil,
        "last_ip" => nil,
        "last_at" => nil,
        "count" => 0
      )

      expect(info["risk_state"]).to include(
        "status" => "Compliant",
        "user_risk_state" => "compliant",
        "suspended" => false,
        "flagged_for_fraud" => false,
        "flagged_for_tos_violation" => false,
        "on_probation" => false,
        "compliant" => true,
        "last_status_changed_at" => nil
      )

      expect(info["payouts"]).to include(
        "paused_internally" => false,
        "paused_by_user" => false,
        "paused_by_source" => nil,
        "paused_for_reason" => nil
      )

      expect(info["stats"]).to include(
        "sales_count" => 0,
        "total_earnings_formatted" => "$0.00",
        "unpaid_balance_formatted" => "$0.00",
        "comments_count" => 0
      )
    end

    it "includes populated social handles and OAuth provider" do
      user = create(:compliant_user,
                    twitter_user_id: "1",
                    twitter_handle: "alice",
                    facebook_uid: "fb1",
                    google_uid: "gid1",
                    provider: "google_oauth2")

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["social"]).to eq(
        "twitter_user_id" => "1",
        "twitter_handle" => "alice",
        "facebook_uid" => "fb1",
        "google_uid" => "gid1",
        "oauth_provider" => "google_oauth2",
        "external_authentications" => []
      )
    end

    it "includes blank social fields with an empty external authentications list" do
      user = create(:compliant_user,
                    twitter_user_id: nil,
                    twitter_handle: nil,
                    facebook_uid: nil,
                    google_uid: nil,
                    provider: nil)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["social"]).to eq(
        "twitter_user_id" => nil,
        "twitter_handle" => nil,
        "facebook_uid" => nil,
        "google_uid" => nil,
        "oauth_provider" => nil,
        "external_authentications" => []
      )
    end

    it "includes linked external authentications" do
      user = create(:compliant_user)
      authentication = create(:user_external_authentication, user:, provider: "apple", uid: "001-test")

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["social"]["external_authentications"]).to contain_exactly(
        {
          "provider" => "apple",
          "uid" => "001-test",
          "linked_at" => authentication.created_at.as_json
        }
      )
    end

    it "orders linked external authentications by creation time" do
      user = create(:compliant_user)
      newer = create(:user_external_authentication, user:, provider: "apple", uid: "newer", created_at: 1.day.ago)
      older = create(:user_external_authentication, user:, provider: "apple", uid: "older", created_at: 2.days.ago)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["social"]["external_authentications"]).to eq(
        [
          {
            "provider" => "apple",
            "uid" => "older",
            "linked_at" => older.created_at.as_json
          },
          {
            "provider" => "apple",
            "uid" => "newer",
            "linked_at" => newer.created_at.as_json
          }
        ]
      )
    end

    it "does not expose credential fields or token values" do
      user = create(:compliant_user)
      user.update_columns(
        twitter_oauth_token: "secret-twitter-token",
        twitter_oauth_secret: "secret-twitter-secret",
        facebook_access_token: "secret-facebook-token",
        otp_secret_key: "secret-otp-key",
        reset_password_token: "secret-reset-token",
        encrypted_password: "secret-encrypted-password"
      )

      get :info, params: { email: user.email }

      credential_patterns = %w[
        twitter_oauth_token
        twitter_oauth_secret
        facebook_access_token
        otp_secret_key
        reset_password_token
        encrypted_password
        secret-twitter-token
        secret-twitter-secret
        secret-facebook-token
        secret-otp-key
        secret-reset-token
        secret-encrypted-password
      ]
      expect(response.body).not_to match(Regexp.union(credential_patterns))
    end

    it "includes populated sign-in tracking fields" do
      current_sign_in_at = 1.hour.ago.change(usec: 0)
      last_sign_in_at = 2.days.ago.change(usec: 0)
      user = create(:compliant_user,
                    account_created_ip: "1.2.3.4",
                    current_sign_in_ip: "5.6.7.8",
                    current_sign_in_at:,
                    last_sign_in_ip: "9.10.11.12",
                    last_sign_in_at:,
                    sign_in_count: 42)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["sign_in"]).to eq(
        "account_created_ip" => "1.2.3.4",
        "current_ip" => "5.6.7.8",
        "current_at" => current_sign_in_at.as_json,
        "last_ip" => "9.10.11.12",
        "last_at" => last_sign_in_at.as_json,
        "count" => 42
      )
    end

    it "reports the suspension status and latest status timestamp for a suspended user" do
      user = create(:tos_user, email: "suspended@example.com")
      comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 2.days.ago)

      get :info, params: { email: user.email }

      info = response.parsed_body["user"]
      expect(info["risk_state"]).to include(
        "status" => "Suspended",
        "suspended" => true,
        "compliant" => false,
        "last_status_changed_at" => comment.created_at.as_json
      )
    end

    it "reflects two-factor authentication when enabled" do
      user = create(:compliant_user, email: "tfa@example.com")
      user.update!(two_factor_authentication_enabled: true)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["two_factor_authentication_enabled"]).to be(true)
    end

    it "surfaces the country from the alive user compliance info" do
      user = create(:compliant_user, email: "geo@example.com")
      create(:user_compliance_info, user:, country: "Germany")

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["country"]).to eq("Germany")
    end

    it "reports admin-paused payouts with the latest pause comment as the reason" do
      user = create(:compliant_user, email: "paused@example.com")
      user.update!(payouts_paused_internally: true, payouts_paused_by: GUMROAD_ADMIN_ID)
      user.comments.create!(author_id: GUMROAD_ADMIN_ID, comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED, content: "Manual review pending")

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["payouts"]).to include(
        "paused_internally" => true,
        "paused_by_source" => User::PAYOUT_PAUSE_SOURCE_ADMIN,
        "paused_for_reason" => "Manual review pending"
      )
    end

    it "reports system-paused payouts without exposing a paused_for_reason" do
      user = create(:compliant_user, email: "syspaused@example.com")
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["payouts"]).to include(
        "paused_internally" => true,
        "paused_by_source" => User::PAYOUT_PAUSE_SOURCE_SYSTEM,
        "paused_for_reason" => nil
      )
    end

    it "reports paused_by_user when the seller has self-paused via Settings" do
      user = create(:compliant_user, email: "selfpaused@example.com")
      user.update!(payouts_paused_by_user: true)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["payouts"]).to include(
        "paused_internally" => false,
        "paused_by_user" => true,
        "paused_by_source" => User::PAYOUT_PAUSE_SOURCE_USER
      )
    end

    it "surfaces a deactivated user with a populated deleted_at" do
      user = create(:compliant_user, email: "deactivated@example.com")
      user.deactivate!

      get :info, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      info = response.parsed_body["user"]
      expect(info["id"]).to eq(user.external_id)
      expect(info["deleted_at"]).to eq(user.reload.deleted_at.as_json)
    end

    it "looks up a soft-deleted user by user_id" do
      user = create(:compliant_user, email: "deleted-by-id@example.com")
      user.mark_deleted!

      get :info, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      info = response.parsed_body["user"]
      expect(info["id"]).to eq(user.external_id)
      expect(info["deleted_at"]).to eq(user.reload.deleted_at.as_json)
    end

    include_examples "supports user lookup by user_id", :info, method: :get, build_user: -> { create(:compliant_user) }

    it "uses the latest risk-state comment for last_status_changed_at, including on_probation transitions" do
      user = create(:compliant_user, email: "probation@example.com")
      create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_COMPLIANT, created_at: 1.month.ago)
      probation_comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_ON_PROBATION, created_at: 1.day.ago)
      user.update_column(:user_risk_state, "on_probation")

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["risk_state"]).to include(
        "user_risk_state" => "on_probation",
        "on_probation" => true,
        "last_status_changed_at" => probation_comment.created_at.as_json
      )
    end

    it "computes sales_count and total_earnings_formatted from the seller's successful sales" do
      seller = create(:compliant_user, email: "earner@example.com")
      product = create(:product, user: seller)
      create(:free_purchase, link: product, seller:)
      create(:free_purchase, link: product, seller:)
      create(:failed_purchase, link: product, seller:)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(1500)

      get :info, params: { email: seller.email }

      stats = response.parsed_body["user"]["stats"]
      expect(stats["sales_count"]).to eq(2)
      expect(stats["total_earnings_formatted"]).to eq("$15.00")
    end

    it "includes the active watched user" do
      user = create(:compliant_user, email: "watched@example.com")
      watched_user = create(:watched_user,
                            user:,
                            revenue_threshold_cents: 20_000,
                            revenue_cents: 12_500,
                            unpaid_balance_cents: 2_500,
                            notes: "Review again")
      watched_user.update!(last_synced_at: 1.hour.ago)

      get :info, params: { email: user.email }

      expect(response.parsed_body["user"]["active_watched_user"]).to eq(
        "id" => watched_user.external_id,
        "revenue_threshold_cents" => 20_000,
        "revenue_cents" => 12_500,
        "unpaid_balance_cents" => 2_500,
        "notes" => "Review again",
        "created_at" => watched_user.created_at.iso8601,
        "last_synced_at" => watched_user.last_synced_at.iso8601
      )
    end
  end

  describe "GET affiliates" do
    include_examples "admin api authorization required", :get, :affiliates

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    def affiliate_payload(external_id)
      response.parsed_body["affiliates"].find { _1["id"] == external_id }
    end

    it "returns bad request when direction is missing" do
      user = create(:user)

      get :affiliates, params: { user_id: user.external_id }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "direction must be 'granted' or 'received'" }.as_json)
    end

    it "returns bad request when direction is invalid" do
      user = create(:user)

      get :affiliates, params: { user_id: user.external_id, direction: "both" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "direction must be 'granted' or 'received'" }.as_json)
    end

    it "returns bad request when neither user_id nor email is provided" do
      get :affiliates, params: { direction: "granted" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :affiliates, params: { user_id: "missing", direction: "granted" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns an empty list with cursor pagination metadata" do
      user = create(:user)

      get :affiliates, params: { email: user.email, direction: "received" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "direction" => "received",
        "affiliates" => [],
        "pagination" => { "next" => nil, "limit" => 20 }
      )
    end

    it "looks up soft-deleted users" do
      user = create(:user, :deleted)

      get :affiliates, params: { user_id: user.external_id, direction: "granted" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
    end

    it "does not write an admin audit log" do
      user = create(:user)

      expect do
        get :affiliates, params: { user_id: user.external_id, direction: "granted" }
      end.not_to change { AdminApiAuditLog.count }
    end

    it "lists granted direct affiliates and collaborators with affiliate users as counterparties" do
      seller = create(:user, email: "seller@example.com")
      direct_affiliate_user = create(:user, email: "direct@example.com", name: "Direct Affiliate")
      collaborator_user = create(:user, email: "collab@example.com", name: "Collaborator User")
      direct_product = create(:product, user: seller, name: "Direct guide")
      collaborator_product = create(:product, user: seller, name: "Collab guide")
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user: direct_affiliate_user, affiliate_basis_points: 1000, products: [direct_product], created_at: 2.hours.ago)
      ProductAffiliate.find_by!(affiliate: direct_affiliate, product: direct_product).update!(affiliate_basis_points: nil)
      collaborator = create(:collaborator, seller:, affiliate_user: collaborator_user, apply_to_all_products: false, affiliate_basis_points: 2000, created_at: 1.hour.ago)
      create(:product_affiliate, affiliate: collaborator, product: collaborator_product, affiliate_basis_points: 1500)

      get :affiliates, params: { user_id: seller.external_id, direction: "granted" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([collaborator.external_id, direct_affiliate.external_id])
      direct_payload = affiliate_payload(direct_affiliate.external_id)
      expect(direct_payload).to include(
        "type" => "DirectAffiliate",
        "direction" => "granted",
        "affiliate_basis_points" => 1000,
        "apply_to_all_products" => false,
        "alive" => true,
        "deleted_at" => nil,
        "created_at" => direct_affiliate.created_at.as_json
      )
      expect(direct_payload["counterparty"]).to eq(
        "id" => direct_affiliate_user.external_id,
        "email" => "direct@example.com",
        "name" => "Direct Affiliate"
      )
      expect(direct_payload["products"]).to contain_exactly(
        {
          "id" => direct_product.external_id,
          "name" => "Direct guide",
          "basis_points" => 1000,
          "destination_url" => nil
        }
      )

      collaborator_payload = affiliate_payload(collaborator.external_id)
      expect(collaborator_payload).to include(
        "type" => "Collaborator",
        "direction" => "granted",
        "affiliate_basis_points" => 2000
      )
      expect(collaborator_payload["counterparty"]).to include(
        "id" => collaborator_user.external_id,
        "email" => "collab@example.com",
        "name" => "Collaborator User"
      )
      expect(collaborator_payload["products"]).to contain_exactly(
        {
          "id" => collaborator_product.external_id,
          "name" => "Collab guide",
          "basis_points" => 1500,
          "destination_url" => nil
        }
      )
    end

    it "lists received affiliates with sellers as counterparties" do
      affiliate_user = create(:user, email: "affiliate@example.com")
      seller = create(:user, email: "seller@example.com", name: "Seller User")
      product = create(:product, user: seller, name: "Seller guide")
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user:, affiliate_basis_points: 1200, products: [product])

      get :affiliates, params: { email: affiliate_user.email, direction: "received" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([direct_affiliate.external_id])
      payload = response.parsed_body["affiliates"].first
      expect(payload).to include(
        "type" => "DirectAffiliate",
        "direction" => "received",
        "affiliate_basis_points" => 1200
      )
      expect(payload["counterparty"]).to eq(
        "id" => seller.external_id,
        "email" => "seller@example.com",
        "name" => "Seller User"
      )
    end

    it "excludes global affiliates" do
      user = create(:user)
      product = create(:product)
      create(:product_affiliate, affiliate: user.global_affiliate, product:)

      get :affiliates, params: { user_id: user.external_id, direction: "received" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"]).to eq([])
    end

    it "includes soft-deleted affiliates" do
      seller = create(:user)
      affiliate_user = create(:user)
      deleted_at = 1.day.ago
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user:, deleted_at:)

      get :affiliates, params: { user_id: seller.external_id, direction: "granted" }

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body["affiliates"].first
      expect(payload).to include(
        "id" => direct_affiliate.external_id,
        "alive" => false,
        "deleted_at" => deleted_at.as_json
      )
    end

    it "falls back to the parent basis points when a product row has no override" do
      seller = create(:user)
      affiliate_user = create(:user)
      product = create(:product, user: seller)
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user:, affiliate_basis_points: 1800, products: [product])
      ProductAffiliate.find_by!(affiliate: direct_affiliate, product:).update!(affiliate_basis_points: nil)

      get :affiliates, params: { user_id: seller.external_id, direction: "granted" }

      expect(response.parsed_body["affiliates"].first["products"].first["basis_points"]).to eq(1800)
    end

    it "uses product basis points when a product row has an override" do
      seller = create(:user)
      affiliate_user = create(:user)
      product = create(:product, user: seller)
      collaborator = create(:collaborator, seller:, affiliate_user:, apply_to_all_products: false, affiliate_basis_points: 2000)
      create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 2500, destination_url: "https://example.com/collab")

      get :affiliates, params: { user_id: seller.external_id, direction: "granted" }

      expect(response.parsed_body["affiliates"].first["products"]).to contain_exactly(
        {
          "id" => product.external_id,
          "name" => product.name,
          "basis_points" => 2500,
          "destination_url" => "https://example.com/collab"
        }
      )
    end

    it "reflects apply_to_all_products without expanding blanket relationships into products" do
      seller = create(:user)
      affiliate_user = create(:user)
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user:, apply_to_all_products: true)

      get :affiliates, params: { user_id: seller.external_id, direction: "granted" }

      payload = response.parsed_body["affiliates"].first
      expect(payload).to include(
        "id" => direct_affiliate.external_id,
        "apply_to_all_products" => true,
        "products" => []
      )
    end

    it "paginates affiliates with a cursor" do
      seller = create(:user)
      newest = create(:direct_affiliate, seller:, affiliate_user: create(:user), created_at: 1.hour.ago)
      middle = create(:direct_affiliate, seller:, affiliate_user: create(:user), created_at: 2.hours.ago)
      oldest = create(:direct_affiliate, seller:, affiliate_user: create(:user), created_at: 3.hours.ago)

      get :affiliates, params: { user_id: seller.external_id, direction: "granted", limit: 2 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([newest.external_id, middle.external_id])
      cursor = response.parsed_body["pagination"]["next"]
      expect(cursor).to be_present
      expect(response.parsed_body["pagination"]["limit"]).to eq(2)

      get :affiliates, params: { user_id: seller.external_id, direction: "granted", limit: 2, cursor: }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([oldest.external_id])
      expect(response.parsed_body["pagination"]).to eq({ "next" => nil, "limit" => 2 })
    end

    it "returns bad request when the cursor is invalid" do
      user = create(:user)

      get :affiliates, params: { user_id: user.external_id, direction: "granted", cursor: "invalid" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
    end

    it "applies a granted cursor to the received scope without binding the cursor to the direction" do
      user = create(:user)
      granted_anchor = create(:direct_affiliate, seller: user, affiliate_user: create(:user), created_at: 3.days.ago)
      create(:direct_affiliate, seller: user, affiliate_user: create(:user), created_at: 4.days.ago)
      newer_received = create(:direct_affiliate, seller: create(:user), affiliate_user: user, created_at: 2.days.ago)
      older_received = create(:direct_affiliate, seller: create(:user), affiliate_user: user, created_at: 4.days.ago)

      get :affiliates, params: { user_id: user.external_id, direction: "granted", limit: 1 }

      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([granted_anchor.external_id])
      cursor = response.parsed_body["pagination"]["next"]

      get :affiliates, params: { user_id: user.external_id, direction: "received", limit: 2, cursor: }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([older_received.external_id])
      expect(response.parsed_body["affiliates"].map { _1["id"] }).not_to include(newer_received.external_id)
    end

    it "scopes results to the requested user" do
      seller = create(:user)
      other_seller = create(:user)
      matching_affiliate = create(:direct_affiliate, seller:, affiliate_user: create(:user))
      create(:direct_affiliate, seller: other_seller, affiliate_user: create(:user))

      get :affiliates, params: { user_id: seller.external_id, direction: "granted" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].map { _1["id"] }).to eq([matching_affiliate.external_id])
    end

    it "preloads received affiliate products and sellers instead of issuing one query per affiliate" do
      affiliate_user = create(:user)
      3.times do
        seller = create(:user)
        products = create_list(:product, 2, user: seller)
        create(:direct_affiliate, seller:, affiliate_user:, products:)
      end
      select_queries = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s.squish
        next if payload[:name] == "SCHEMA"
        next unless sql.start_with?("SELECT")
        next if sql.include?("`admin_api_tokens`")
        next if sql.include?("`oauth_access_tokens`")

        select_queries << sql
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :affiliates, params: { user_id: affiliate_user.external_id, direction: "received" }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["affiliates"].length).to eq(3)
      expect(select_queries.length).to be <= 6, "expected at most 6 SELECTs but got #{select_queries.length}:\n#{select_queries.join("\n")}"
    end

    include_examples "supports user lookup by user_id", :affiliates, method: :get, extra_params: { direction: "granted" }
  end

  describe "GET comments" do
    include_examples "admin api authorization required", :get, :comments

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    def comment_ids
      response.parsed_body["comments"].map { _1["id"] }
    end

    it "returns bad request when neither user_id nor email is provided" do
      get :comments

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :comments, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns an empty list with cursor pagination metadata" do
      user = create(:user)

      get :comments, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "comments" => [],
        "pagination" => { "next" => nil, "limit" => 20 }
      )
    end

    it "looks up soft-deleted users" do
      user = create(:user, :deleted)

      get :comments, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
    end

    it "lists comments for the user ordered by created_at and id descending" do
      user = create(:user)
      timestamp = 1.hour.ago.change(usec: 0)
      older = create(:comment, commentable: user, author: admin_user, author_name: "Older Admin", comment_type: Comment::COMMENT_TYPE_NOTE, content: "Older note", created_at: 2.hours.ago)
      first_same_time = create(:comment, commentable: user, author: admin_user, author_name: "First Admin", comment_type: Comment::COMMENT_TYPE_NOTE, content: "First note", created_at: timestamp)
      second_same_time = create(:comment, commentable: user, author: admin_user, author_name: "Second Admin", comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE, content: "Second note", created_at: timestamp)

      get :comments, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(comment_ids).to eq([second_same_time.external_id, first_same_time.external_id, older.external_id])
      expect(response.parsed_body["comments"].first).to include(
        "id" => second_same_time.external_id,
        "author_name" => "Second Admin",
        "content" => "Second note",
        "comment_type" => Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        "created_at" => second_same_time.created_at.iso8601,
        "deleted_at" => nil,
        "alive" => true
      )
    end

    it "falls back to the author name and then System when the snapshot is blank" do
      user = create(:user)
      author = create(:admin_user, name: "Riley Admin")
      snapshot = create(:comment, commentable: user, author:, author_name: "Snapshot Name", comment_type: Comment::COMMENT_TYPE_NOTE)
      author_fallback = create(:comment, commentable: user, author:, author_name: nil, comment_type: Comment::COMMENT_TYPE_NOTE)
      system_fallback = create(:comment, commentable: user, author:, author_name: "Temporary", comment_type: Comment::COMMENT_TYPE_NOTE)
      system_fallback.update_columns(author_id: nil, author_name: nil)

      get :comments, params: { user_id: user.external_id }

      payloads = response.parsed_body["comments"].index_by { _1["id"] }
      expect(payloads[snapshot.external_id]["author_name"]).to eq("Snapshot Name")
      expect(payloads[author_fallback.external_id]["author_name"]).to eq("Riley Admin")
      expect(payloads[system_fallback.external_id]["author_name"]).to eq("System")
    end

    it "filters to a single comment_type" do
      user = create(:user)
      note = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE)
      create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE)

      get :comments, params: { user_id: user.external_id, comment_type: "note" }

      expect(response).to have_http_status(:ok)
      expect(comment_ids).to eq([note.external_id])
    end

    it "filters to multiple comment types from a comma-separated list" do
      user = create(:user)
      note = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, created_at: 2.hours.ago)
      suspension_note = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE, created_at: 1.hour.ago)
      create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_FLAGGED, created_at: 30.minutes.ago)

      get :comments, params: { user_id: user.external_id, comment_type: "note,suspension_note" }

      expect(response).to have_http_status(:ok)
      expect(comment_ids).to eq([suspension_note.external_id, note.external_id])
    end

    it "rejects an unknown comment_type value" do
      user = create(:user)

      get :comments, params: { user_id: user.external_id, comment_type: "bogus" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "comment_type contains invalid value: bogus" }.as_json)
    end

    it "rejects a comma-separated comment_type list with any invalid value" do
      user = create(:user)

      get :comments, params: { user_id: user.external_id, comment_type: "note,bogus" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "comment_type contains invalid value: bogus" }.as_json)
    end

    it "rejects a comma-only comment_type value instead of silently returning all comments" do
      user = create(:user)
      create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE)

      get :comments, params: { user_id: user.external_id, comment_type: "," }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "comment_type contains invalid value: ," }.as_json)
    end

    it "includes soft-deleted comments with deletion state exposed" do
      user = create(:user)
      deleted_comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE)
      deleted_comment.mark_deleted!

      get :comments, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body["comments"].first
      expect(payload).to include(
        "id" => deleted_comment.external_id,
        "alive" => false,
        "deleted_at" => deleted_comment.reload.deleted_at.iso8601
      )
    end

    it "scopes results to the requested user and excludes comments on other records" do
      user = create(:user)
      matching = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE)
      create(:comment, commentable: create(:user), comment_type: Comment::COMMENT_TYPE_NOTE)
      create(:comment, commentable: create(:purchase), comment_type: Comment::COMMENT_TYPE_NOTE)

      get :comments, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(comment_ids).to eq([matching.external_id])
    end

    it "paginates comments with a cursor" do
      user = create(:user)
      newest = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, created_at: 1.hour.ago)
      middle = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, created_at: 2.hours.ago)
      oldest = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, created_at: 3.hours.ago)

      get :comments, params: { user_id: user.external_id, limit: 2 }

      expect(response).to have_http_status(:ok)
      expect(comment_ids).to eq([newest.external_id, middle.external_id])
      cursor = response.parsed_body["pagination"]["next"]
      expect(cursor).to be_present
      expect(response.parsed_body["pagination"]["limit"]).to eq(2)

      get :comments, params: { user_id: user.external_id, limit: 2, cursor: }

      expect(response).to have_http_status(:ok)
      expect(comment_ids).to eq([oldest.external_id])
      expect(response.parsed_body["pagination"]).to eq({ "next" => nil, "limit" => 2 })
    end

    it "returns bad request when the cursor is invalid" do
      user = create(:user)

      get :comments, params: { user_id: user.external_id, cursor: "invalid" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
    end

    it "preloads authors instead of issuing one query per comment" do
      user = create(:user)
      3.times do |index|
        author = create(:admin_user, name: "Admin #{index}")
        create(:comment, commentable: user, author:, author_name: nil, comment_type: Comment::COMMENT_TYPE_NOTE)
      end
      select_queries = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s.squish
        next if payload[:name] == "SCHEMA"
        next unless sql.start_with?("SELECT")
        next if sql.include?("`admin_api_tokens`")
        next if sql.include?("`oauth_access_tokens`")

        select_queries << sql
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :comments, params: { user_id: user.external_id }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["comments"].length).to eq(3)
      expect(select_queries.length).to be <= 4, "expected at most 4 SELECTs but got #{select_queries.length}:\n#{select_queries.join("\n")}"
    end

    include_examples "supports user lookup by user_id", :comments, method: :get
  end

  describe "GET compliance_info" do
    include_examples "admin api authorization required", :get, :compliance_info

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns bad request when neither user_id nor email is provided" do
      get :compliance_info

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :compliance_info, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns null compliance_info and an empty info_requests list when the user has never submitted KYC" do
      user = create(:user)

      get :compliance_info, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "success" => true,
        "user_id" => user.external_id,
        "compliance_info" => nil,
        "info_requests" => []
      )
    end

    it "looks up soft-deleted users" do
      user = create(:user, :deleted)

      get :compliance_info, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
    end

    it "does not write an admin audit log" do
      user = create(:user)

      expect do
        get :compliance_info, params: { user_id: user.external_id }
      end.not_to change { AdminApiAuditLog.count }
    end

    it "returns submitted KYC fields for an individual seller with the tax ID masked to last four" do
      user = create(:user)
      info = create(:user_compliance_info,
                    user:,
                    first_name: "Alice",
                    last_name: "Investigator",
                    dba: "Alice & Co",
                    birthday: Date.new(1985, 6, 7),
                    individual_tax_id: "123456789",
                    nationality: "US",
                    phone: "5551234567",
                    job_title: "Owner",
                    stripe_identity_document_id: "idoc_individual")

      get :compliance_info, params: { user_id: user.external_id }

      payload = response.parsed_body["compliance_info"]
      expect(payload).to include(
        "id" => info.external_id,
        "is_business" => false,
        "first_name" => "Alice",
        "last_name" => "Investigator",
        "legal_name" => "Alice Investigator",
        "dba" => "Alice & Co",
        "birthday" => "1985-06-07",
        "nationality" => "US",
        "phone" => "5551234567",
        "job_title" => "Owner",
        "business_name" => nil,
        "business_type" => nil,
        "business_phone" => nil,
        "business_vat_id_number" => nil,
        "business_address" => nil
      )
      expect(payload["address"]).to eq(
        "street_address" => "address_full_match",
        "city" => "San Francisco",
        "state" => "California",
        "state_code" => "CA",
        "zip_code" => "94107",
        "country" => "United States",
        "country_code" => "US"
      )
      expect(payload["tax_ids"]).to eq(
        "individual_last_four" => "6789",
        "business_last_four" => nil
      )
      expect(payload["identity_documents"]).to eq(
        "stripe_identity_document_id" => "idoc_individual",
        "stripe_company_document_id" => nil,
        "stripe_additional_document_id" => nil
      )
      expect(payload["created_at"]).to eq(info.created_at.as_json)
      expect(payload["updated_at"]).to eq(info.updated_at.as_json)
    end

    it "returns business KYC fields with the business address and business tax ID last four" do
      user = create(:user)
      info = create(:user_compliance_info_business,
                    user:,
                    business_name: "Acme LLC",
                    business_type: UserComplianceInfo::BusinessTypes::LLC,
                    business_tax_id: "123456789",
                    business_phone: "5550009999",
                    business_vat_id_number: "GB123456789",
                    stripe_company_document_id: "idoc_company",
                    stripe_additional_document_id: "idoc_additional")

      get :compliance_info, params: { user_id: user.external_id }

      payload = response.parsed_body["compliance_info"]
      expect(payload).to include(
        "id" => info.external_id,
        "is_business" => true,
        "legal_name" => "Acme LLC",
        "business_name" => "Acme LLC",
        "business_type" => UserComplianceInfo::BusinessTypes::LLC,
        "business_phone" => "5550009999",
        "business_vat_id_number" => "GB123456789"
      )
      expect(payload["business_address"]).to eq(
        "street_address" => "address_full_match",
        "city" => "Burbank",
        "state" => "California",
        "state_code" => "CA",
        "zip_code" => "91506",
        "country" => "United States",
        "country_code" => "US"
      )
      expect(payload["tax_ids"]).to eq(
        "individual_last_four" => "0000",
        "business_last_four" => "6789"
      )
      expect(payload["identity_documents"]).to include(
        "stripe_company_document_id" => "idoc_company",
        "stripe_additional_document_id" => "idoc_additional"
      )
    end

    it "returns the latest alive compliance info when older records are soft-deleted" do
      user = create(:user)
      old_info = create(:user_compliance_info, user:, first_name: "Old")
      old_info.mark_deleted!
      newest = create(:user_compliance_info, user:, first_name: "Newest")

      get :compliance_info, params: { user_id: user.external_id }

      expect(response.parsed_body["compliance_info"]["id"]).to eq(newest.external_id)
      expect(response.parsed_body["compliance_info"]["first_name"]).to eq("Newest")
    end

    it "returns the trailing characters of an alphanumeric non-US business_tax_id verbatim" do
      user = create(:user)
      create(:user_compliance_info_business,
             user:,
             country: "Ireland",
             business_country: "Ireland",
             business_tax_id: "3490731JH",
             stripe_company_document_id: "idoc_company")

      get :compliance_info, params: { user_id: user.external_id }

      expect(response.parsed_body["compliance_info"]["tax_ids"]).to include(
        "business_last_four" => "31JH"
      )
    end

    it "omits last_four for tax IDs that were never set" do
      user = create(:user)
      create(:user_compliance_info_empty, user:)

      get :compliance_info, params: { user_id: user.external_id }

      expect(response.parsed_body["compliance_info"]["tax_ids"]).to eq(
        "individual_last_four" => nil,
        "business_last_four" => nil
      )
    end

    it "lists only requested info_requests and excludes provided ones, marking overdue rows" do
      user = create(:user)
      overdue = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID, state: "requested", due_at: 3.days.ago, created_at: 5.days.ago)
      upcoming = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::DATE_OF_BIRTH, state: "requested", due_at: 5.days.from_now, created_at: 2.days.ago)
      undated = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::TAX_ID, state: "requested", due_at: nil, created_at: 1.day.ago)
      create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME, state: "provided", provided_at: 1.day.ago)

      get :compliance_info, params: { user_id: user.external_id }

      rows = response.parsed_body["info_requests"]
      expect(rows.map { _1["id"] }).to eq([overdue, upcoming, undated].map(&:external_id))
      expect(rows.first).to include(
        "field_needed" => UserComplianceInfoFields::Individual::TAX_ID,
        "state" => "requested",
        "due_at" => overdue.due_at.as_json,
        "overdue" => true,
        "created_at" => overdue.created_at.as_json,
        "last_email_sent_at" => nil
      )
      expect(rows[1]).to include(
        "field_needed" => UserComplianceInfoFields::Individual::DATE_OF_BIRTH,
        "overdue" => false
      )
      expect(rows[2]).to include(
        "field_needed" => UserComplianceInfoFields::Business::TAX_ID,
        "due_at" => nil,
        "overdue" => false
      )
    end

    it "exposes the most recent email reminder timestamp when present" do
      user = create(:user)
      request_record = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID, state: "requested", due_at: 1.day.from_now)
      reminder_time = 2.hours.ago.change(usec: 0)
      request_record.record_email_sent!(reminder_time)

      get :compliance_info, params: { user_id: user.external_id }

      row = response.parsed_body["info_requests"].first
      expect(row["last_email_sent_at"]).to eq(reminder_time.as_json)
    end

    it "scopes info_requests to the requested user" do
      user = create(:user)
      other_user = create(:user)
      mine = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID, state: "requested")
      create(:user_compliance_info_request, user: other_user, field_needed: UserComplianceInfoFields::Individual::TAX_ID, state: "requested")

      get :compliance_info, params: { user_id: user.external_id }

      expect(response.parsed_body["info_requests"].map { _1["id"] }).to eq([mine.external_id])
    end

    include_examples "supports user lookup by user_id", :compliance_info, method: :get
  end

  describe "GET purchases" do
    include_examples "admin api authorization required", :get, :purchases

    before do
      stub_const("GUMROAD_ADMIN_ID", admin_user.id)
      allow(Radar::ChargeRiskLevelService).to receive(:fetch_bulk).and_return({})
    end

    let!(:gumroad_merchant_account) { create(:merchant_account, user: nil) }

    def purchase_ids
      response.parsed_body["purchases"].map { _1["id"] }
    end

    it "returns bad request when neither user_id nor email is provided" do
      get :purchases

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :purchases, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns an empty list with cursor pagination metadata" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "purchases" => [],
        "pagination" => { "next" => nil, "limit" => 20 }
      )
    end

    it "looks up soft-deleted users" do
      user = create(:user, :deleted)

      get :purchases, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
    end

    it "does not write an admin audit log" do
      user = create(:user)

      expect do
        get :purchases, params: { user_id: user.external_id }
      end.not_to change { AdminApiAuditLog.count }
    end

    it "returns purchases matched by purchaser_id and by email, newest first" do
      buyer = create(:user, email: "buyer@example.com")
      anonymous_match = create(:purchase, email: buyer.email, created_at: 3.hours.ago)
      logged_in = create(:purchase, purchaser: buyer, email: "other@example.com", created_at: 2.hours.ago)
      newest = create(:purchase, purchaser: buyer, email: buyer.email, created_at: 1.hour.ago)
      create(:purchase, email: "someone-else@example.com", created_at: 30.minutes.ago)

      get :purchases, params: { user_id: buyer.external_id }

      expect(response).to have_http_status(:ok)
      expect(purchase_ids).to eq([newest, logged_in, anonymous_match].map { _1.external_id_numeric.to_s })
    end

    it "serializes each row with the shared purchase payload" do
      buyer = create(:user, email: "buyer@example.com")
      seller = create(:user, email: "seller@example.com")
      product = create(:product, user: seller, name: "Investigation guide")
      purchase = create(:purchase, purchaser: buyer, seller:, link: product, email: buyer.email, price_cents: 12_34)

      get :purchases, params: { user_id: buyer.external_id }

      payload = response.parsed_body["purchases"].first
      expect(payload).to include(
        "id" => purchase.external_id_numeric.to_s,
        "email" => buyer.email,
        "seller_email" => "seller@example.com",
        "seller" => {
          "id" => seller.external_id,
          "email" => "seller@example.com",
          "name" => seller.name,
        },
        "product_name" => "Investigation guide",
        "price_cents" => 12_34,
        "purchase_state" => "successful"
      )
    end

    it "serializes nil seller fields when a purchase has no seller" do
      buyer = create(:user, email: "buyer@example.com")
      purchase = create(:free_purchase, purchaser: buyer, email: buyer.email)
      purchase.update_columns(seller_id: nil)

      get :purchases, params: { user_id: buyer.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].first).to include(
        "id" => purchase.external_id_numeric.to_s,
        "seller_email" => nil,
        "seller" => nil
      )
    end

    it "filters by a single purchase_state" do
      buyer = create(:user)
      successful = create(:purchase, purchaser: buyer)
      create(:failed_purchase, purchaser: buyer)

      get :purchases, params: { user_id: buyer.external_id, status: "successful" }

      expect(purchase_ids).to eq([successful.external_id_numeric.to_s])
    end

    it "filters by multiple purchase states from a comma-separated list" do
      buyer = create(:user)
      successful = create(:purchase, purchaser: buyer, created_at: 2.hours.ago)
      failed = create(:failed_purchase, purchaser: buyer, created_at: 1.hour.ago)
      create(:purchase, purchaser: buyer, purchase_state: "not_charged", created_at: 30.minutes.ago)

      get :purchases, params: { user_id: buyer.external_id, status: "successful,failed" }

      expect(purchase_ids).to eq([failed, successful].map { _1.external_id_numeric.to_s })
    end

    it "rejects an unknown status value" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, status: "not_a_state" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to start_with("status must be one of")
    end

    it "rejects a comma-only status value instead of silently returning an empty list" do
      buyer = create(:user)
      create(:purchase, purchaser: buyer)

      get :purchases, params: { user_id: buyer.external_id, status: "," }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to start_with("status must be one of")
    end

    it "accepts every state defined on the Purchase state machine, including preorder_concluded_unsuccessfully" do
      buyer = create(:user)
      purchase = create(:purchase, purchaser: buyer)
      purchase.update_column(:purchase_state, "preorder_concluded_unsuccessfully")

      get :purchases, params: { user_id: buyer.external_id, status: "preorder_concluded_unsuccessfully" }

      expect(response).to have_http_status(:ok)
      expect(purchase_ids).to eq([purchase.external_id_numeric.to_s])
    end

    it "filters by a created_at window using ISO 8601 timestamps" do
      buyer = create(:user)
      too_old = create(:purchase, purchaser: buyer, created_at: 3.days.ago)
      in_window = create(:purchase, purchaser: buyer, created_at: 1.day.ago)
      too_new = create(:purchase, purchaser: buyer, created_at: 1.hour.ago)

      get :purchases, params: {
        user_id: buyer.external_id,
        start_at: 2.days.ago.iso8601,
        end_at: 6.hours.ago.iso8601
      }

      expect(purchase_ids).to eq([in_window.external_id_numeric.to_s])
      expect(purchase_ids).not_to include(too_old.external_id_numeric.to_s, too_new.external_id_numeric.to_s)
    end

    it "rejects an unparseable start_at" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, start_at: "yesterday" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "start_at must be a valid ISO 8601 timestamp" }.as_json)
    end

    it "rejects an unparseable end_at" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, end_at: "soon" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "end_at must be a valid ISO 8601 timestamp" }.as_json)
    end

    it "filters by chargedback=true" do
      buyer = create(:user)
      clean = create(:purchase, purchaser: buyer)
      chargedback = create(:purchase, purchaser: buyer, chargeback_date: 1.day.ago)

      get :purchases, params: { user_id: buyer.external_id, chargedback: true }

      expect(purchase_ids).to eq([chargedback.external_id_numeric.to_s])
      expect(purchase_ids).not_to include(clean.external_id_numeric.to_s)
    end

    it "filters by chargedback=false" do
      buyer = create(:user)
      clean = create(:purchase, purchaser: buyer)
      create(:purchase, purchaser: buyer, chargeback_date: 1.day.ago)

      get :purchases, params: { user_id: buyer.external_id, chargedback: false }

      expect(purchase_ids).to eq([clean.external_id_numeric.to_s])
    end

    it "rejects an empty chargedback value instead of silently filtering to chargedback=false" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, chargedback: "" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "chargedback must be true or false" }.as_json)
    end

    it "rejects an empty has_early_fraud_warning value" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, has_early_fraud_warning: "" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "has_early_fraud_warning must be true or false" }.as_json)
    end

    it "rejects an unparseable has_affiliate value" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, has_affiliate: "" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "has_affiliate must be true or false" }.as_json)
    end

    it "filters by has_early_fraud_warning=true" do
      buyer = create(:user)
      flagged = create(:purchase, purchaser: buyer)
      create(:early_fraud_warning, purchase: flagged)
      create(:purchase, purchaser: buyer)

      get :purchases, params: { user_id: buyer.external_id, has_early_fraud_warning: true }

      expect(purchase_ids).to eq([flagged.external_id_numeric.to_s])
    end

    it "filters by has_early_fraud_warning=false" do
      buyer = create(:user)
      flagged = create(:purchase, purchaser: buyer)
      create(:early_fraud_warning, purchase: flagged)
      clean = create(:purchase, purchaser: buyer)

      get :purchases, params: { user_id: buyer.external_id, has_early_fraud_warning: false }

      expect(purchase_ids).to eq([clean.external_id_numeric.to_s])
    end

    it "filters by has_affiliate=true" do
      buyer = create(:user)
      seller = create(:user)
      product = create(:product, user: seller)
      affiliate = create(:direct_affiliate, seller:, affiliate_user: create(:user))
      with_affiliate = create(:purchase, purchaser: buyer, seller:, link: product, affiliate:)
      create(:purchase, purchaser: buyer)

      get :purchases, params: { user_id: buyer.external_id, has_affiliate: true }

      expect(purchase_ids).to eq([with_affiliate.external_id_numeric.to_s])
    end

    it "filters by stripe_fingerprint" do
      buyer = create(:user)
      matching = create(:purchase, purchaser: buyer, stripe_fingerprint: "fp_shared")
      create(:purchase, purchaser: buyer, stripe_fingerprint: "fp_other")

      get :purchases, params: { user_id: buyer.external_id, stripe_fingerprint: "fp_shared" }

      expect(purchase_ids).to eq([matching.external_id_numeric.to_s])
    end

    it "filters by ip_address" do
      buyer = create(:user)
      matching = create(:purchase, purchaser: buyer, ip_address: "203.0.113.7")
      create(:purchase, purchaser: buyer, ip_address: "198.51.100.4")

      get :purchases, params: { user_id: buyer.external_id, ip_address: "203.0.113.7" }

      expect(purchase_ids).to eq([matching.external_id_numeric.to_s])
    end

    it "scopes results to the requested user" do
      buyer = create(:user)
      other_buyer = create(:user)
      mine = create(:purchase, purchaser: buyer)
      create(:purchase, purchaser: other_buyer)

      get :purchases, params: { user_id: buyer.external_id }

      expect(purchase_ids).to eq([mine.external_id_numeric.to_s])
    end

    it "skips the email branch when the user has no email so NULL-email purchases are not leaked" do
      oauth_buyer = create(:user, provider: "google_oauth2", google_uid: "g-uid")
      oauth_buyer.update_columns(email: nil)
      own_purchase = create(:purchase, purchaser: oauth_buyer)
      unrelated = create(:purchase)
      unrelated.update_columns(email: nil)

      get :purchases, params: { user_id: oauth_buyer.external_id }

      expect(response).to have_http_status(:ok)
      expect(purchase_ids).to eq([own_purchase.external_id_numeric.to_s])
      expect(purchase_ids).not_to include(unrelated.external_id_numeric.to_s)
    end

    it "paginates purchases with a cursor" do
      buyer = create(:user)
      newest = create(:purchase, purchaser: buyer, created_at: 1.hour.ago)
      middle = create(:purchase, purchaser: buyer, created_at: 2.hours.ago)
      oldest = create(:purchase, purchaser: buyer, created_at: 3.hours.ago)

      get :purchases, params: { user_id: buyer.external_id, limit: 2 }

      expect(response).to have_http_status(:ok)
      expect(purchase_ids).to eq([newest, middle].map { _1.external_id_numeric.to_s })
      cursor = response.parsed_body["pagination"]["next"]
      expect(cursor).to be_present
      expect(response.parsed_body["pagination"]["limit"]).to eq(2)

      get :purchases, params: { user_id: buyer.external_id, limit: 2, cursor: }

      expect(response).to have_http_status(:ok)
      expect(purchase_ids).to eq([oldest.external_id_numeric.to_s])
      expect(response.parsed_body["pagination"]).to eq({ "next" => nil, "limit" => 2 })
    end

    it "returns bad request when the cursor is invalid" do
      user = create(:user)

      get :purchases, params: { user_id: user.external_id, cursor: "invalid" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
    end

    include_examples "supports user lookup by user_id", :purchases, method: :get
  end

  describe "GET related" do
    include_examples "admin api authorization required", :get, :related

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    def credit_card_with_fingerprint(fingerprint)
      CreditCard.create!(
        stripe_fingerprint: fingerprint,
        visual: "**** **** **** 4242",
        card_type: CardType::VISA,
        stripe_customer_id: "cus_#{SecureRandom.hex(6)}",
        expiry_month: 12,
        expiry_year: 2030,
        charge_processor_id: StripeChargeProcessor.charge_processor_id
      )
    end

    def related_user_payload(user)
      response.parsed_body["related_users"].find { _1["id"] == user.external_id }
    end

    it "returns bad request when neither user_id nor email is provided" do
      get :related

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :related, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "rejects unknown signal values" do
      user = create(:user)

      get :related, params: { user_id: user.external_id, signals: "ip,bogus" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "signals contains invalid value: bogus" }.as_json)
    end

    it "rejects a comma-only signals value" do
      user = create(:user)

      get :related, params: { user_id: user.external_id, signals: ",,," }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "signals contains invalid value: ,,," }.as_json)
    end

    it "returns the full default-signals response" do
      target = create(:user,
                      account_created_ip: "1.2.3.4",
                      current_sign_in_ip: nil,
                      last_sign_in_ip: nil,
                      payment_address: "shared-payment@example.com",
                      credit_card: credit_card_with_fingerprint("fp_shared"))
      ip_match = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
      payment_match = create(:user, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "shared-payment@example.com")
      card_match = create(:user, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"))

      get :related, params: { user_id: target.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => target.external_id,
        "signals_evaluated" => %w[ip payment_address card_fingerprint],
        "per_signal_limit" => 50,
        "truncated" => {
          "ip" => false,
          "payment_address" => false,
          "card_fingerprint" => false,
        }
      )
      expect(response.parsed_body["related_users"].map { _1["id"] }).to contain_exactly(ip_match.external_id, payment_match.external_id, card_match.external_id)
      expect(related_user_payload(ip_match)["relations"]).to contain_exactly(
        {
          "signal" => "ip",
          "shared_value" => "1.2.3.4",
          "via" => ["account_created_ip"],
        }
      )
      expect(related_user_payload(payment_match)["relations"]).to eq([
                                                                       {
                                                                         "signal" => "payment_address",
                                                                         "shared_value" => "shared-payment@example.com",
                                                                       }
                                                                     ])
      expect(related_user_payload(card_match)["relations"]).to eq([
                                                                    {
                                                                      "signal" => "card_fingerprint",
                                                                      "shared_value" => nil,
                                                                    }
                                                                  ])
    end

    it "scopes related users to the requested signals" do
      target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "shared-payment@example.com")
      ip_match = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
      payment_match = create(:user, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "shared-payment@example.com")

      get :related, params: { user_id: target.external_id, signals: "ip" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["signals_evaluated"]).to eq(["ip"])
      expect(response.parsed_body["related_users"].map { _1["id"] }).to eq([ip_match.external_id])
      expect(response.parsed_body["related_users"].map { _1["id"] }).not_to include(payment_match.external_id)
    end

    it "applies the per-signal limit and reports truncation" do
      target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
      create_list(:user, 3, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)

      get :related, params: { user_id: target.external_id, signals: "ip", limit: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["per_signal_limit"]).to eq(1)
      expect(response.parsed_body["related_users"].length).to eq(1)
      expect(response.parsed_body["truncated"]).to eq("ip" => true)
    end

    it "includes each related user's risk state" do
      target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
      related = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil, user_risk_state: "suspended_for_fraud")
      create(:comment, commentable: related, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 1.hour.ago)

      get :related, params: { user_id: target.external_id, signals: "ip" }

      expect(response).to have_http_status(:ok)
      expect(related_user_payload(related)["risk_state"]).to eq(Admin::UserRiskStatePresenter.new(related).props.as_json)
    end

    it "keeps related user enrichment queries bounded" do
      target = create(:user,
                      account_created_ip: "1.2.3.4",
                      current_sign_in_ip: nil,
                      last_sign_in_ip: nil,
                      payment_address: "shared-payment@example.com",
                      credit_card: credit_card_with_fingerprint("fp_shared"))
      5.times do
        related = create(:user,
                         account_created_ip: "1.2.3.4",
                         current_sign_in_ip: nil,
                         last_sign_in_ip: nil,
                         payment_address: "shared-payment@example.com",
                         credit_card: credit_card_with_fingerprint("fp_shared"))
        create(:comment, commentable: related, comment_type: Comment::COMMENT_TYPE_SUSPENDED)
      end

      select_queries = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s.squish
        next if payload[:name] == "SCHEMA"
        next unless sql.start_with?("SELECT")
        next if sql.include?("`admin_api_tokens`")
        next if sql.include?("`oauth_access_tokens`")

        select_queries << sql
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :related, params: { user_id: target.external_id }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["related_users"].length).to eq(5)
      expect(select_queries.length).to be <= 8, "expected at most 8 SELECTs but got #{select_queries.length}:\n#{select_queries.join("\n")}"
    end

    include_examples "supports user lookup by user_id", :related, method: :get
  end

  describe "GET suspension" do
    include_examples "admin api authorization required", :get, :suspension

    it "returns compliant status for an unsuspended user" do
      user = create(:compliant_user, email: "seller@example.com")

      get :suspension, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        user_id: user.external_id,
        status: "Compliant",
        updated_at: nil,
        appeal_url: nil
      }.as_json)
    end

    it "returns suspended status with the latest status comment timestamp" do
      user = create(:tos_user, email: "suspended@example.com")
      comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 2.days.ago)

      get :suspension, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        user_id: user.external_id,
        status: "Suspended",
        updated_at: comment.created_at.as_json,
        appeal_url: nil
      }.as_json)
    end

    it "returns a bad request when email is missing" do
      get :suspension

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email or user_id is required" }.as_json)
    end

    it "returns not found when the user does not exist" do
      get :suspension, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "returns not found when user_id matches a soft-deleted user" do
      user = create(:compliant_user)
      user.mark_deleted!

      get :suspension, params: { user_id: user.external_id }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    include_examples "supports user lookup by user_id", :suspension, method: :get, build_user: -> { create(:compliant_user) }
  end

  describe "POST reset_password" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :reset_password

    it "returns 400 when user_id is missing" do
      post :reset_password

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    include_examples "requires user_id for user mutation", :reset_password

    it "returns 404 when the user does not exist" do
      post :reset_password, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "sends reset password instructions and returns success" do
      expect_any_instance_of(User).to receive(:send_reset_password_instructions)

      post :reset_password, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ success: true, user_id: user.external_id, message: "Reset password instructions sent" }.as_json)
    end

    context "with a user lookup helper stubbed" do
      before { allow_any_instance_of(User).to receive(:send_reset_password_instructions) }

      include_examples "supports user lookup by user_id", :reset_password
      include_examples "checks expected_email for user mutation", :reset_password
    end
  end

  describe "POST update_email" do
    let(:user) { create(:user) }
    let(:new_email) { "fresh@example.com" }

    include_examples "admin api authorization required", :post, :update_email

    it "returns 400 when user_id is missing" do
      post :update_email, params: { new_email: new_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 400 when new_email is missing" do
      post :update_email, params: { user_id: user.external_id }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "new_email is required" }.as_json)
    end

    it "returns 400 when new_email is malformed" do
      post :update_email, params: { user_id: user.external_id, new_email: "not-an-email" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Invalid new email format" }.as_json)
    end

    it "returns 404 when user_id does not match a user" do
      post :update_email, params: { user_id: "missing", new_email: new_email }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "updates the email and returns the pending confirmation state" do
      post :update_email, params: { user_id: user.external_id, new_email: new_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
      expect(response.parsed_body["message"]).to include("Email change pending confirmation")
      expect(response.parsed_body["unconfirmed_email"]).to eq(new_email)
      expect(response.parsed_body["pending_confirmation"]).to be(true)
      expect(user.reload.unconfirmed_email).to eq(new_email)
    end

    it "returns 422 when the new email collides with an existing user" do
      other_user = create(:user)

      post :update_email, params: { user_id: user.external_id, new_email: other_user.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns 422 when the new email matches the current email" do
      post :update_email, params: { user_id: user.external_id, new_email: user.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({ success: false, message: "New email is the same as the current email" }.as_json)
      expect(user.reload.unconfirmed_email).to be_nil
    end

    it "rejects same-email submissions case-insensitively" do
      post :update_email, params: { user_id: user.external_id, new_email: user.email.upcase }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("New email is the same as the current email")
    end

    it "accepts expected_email when it matches the target user" do
      post :update_email, params: { user_id: user.external_id, expected_email: user.email.upcase, new_email: new_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(user.reload.unconfirmed_email).to eq(new_email)
    end

    it "returns 400 when only current_email is provided" do
      post :update_email, params: { current_email: user.email, new_email: new_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 404 when user_id matches a soft-deleted user" do
      user.mark_deleted!

      post :update_email, params: { user_id: user.external_id, new_email: new_email }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "uses user_id as the lookup key when current_email is also provided" do
      other_user = create(:user)

      post :update_email, params: { user_id: user.external_id, current_email: other_user.email, new_email: new_email }

      expect(response).to have_http_status(:ok)
      expect(user.reload.unconfirmed_email).to eq(new_email)
      expect(other_user.reload.unconfirmed_email).to be_nil
    end

    include_examples "requires user_id for user mutation", :update_email, extra_params: { new_email: "fresh@example.com" }
    include_examples "checks expected_email for user mutation", :update_email, extra_params: { new_email: "fresh@example.com" }
  end

  describe "POST two_factor_authentication" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :two_factor_authentication

    it "returns 400 when user_id is missing" do
      post :two_factor_authentication, params: { enabled: true }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 400 when enabled is missing" do
      post :two_factor_authentication, params: { user_id: user.external_id }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "enabled is required" }.as_json)
    end

    it "returns 400 when enabled is an empty string and does not modify the user" do
      user.update!(two_factor_authentication_enabled: true)
      totp_credential = TotpCredential.create!(user: user)

      post :two_factor_authentication, params: { user_id: user.external_id, enabled: "" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "enabled is required" }.as_json)
      expect(user.reload.two_factor_authentication_enabled?).to be(true)
      expect(TotpCredential.where(id: totp_credential.id)).to exist
    end

    it "treats Ruby false as a valid disable request" do
      user.update!(two_factor_authentication_enabled: true)

      post :two_factor_authentication, params: { user_id: user.external_id, enabled: false }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["two_factor_authentication_enabled"]).to be(false)
    end

    it "returns 404 when the user does not exist" do
      post :two_factor_authentication, params: { user_id: "missing", enabled: true }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "enables two-factor authentication" do
      user.update!(two_factor_authentication_enabled: false)

      post :two_factor_authentication, params: { user_id: user.external_id, enabled: true }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "message" => "Two-factor authentication enabled",
        "two_factor_authentication_enabled" => true
      )
      expect(user.reload.two_factor_authentication_enabled?).to be(true)
    end

    it "disables two-factor authentication and destroys the totp credential" do
      user.update!(two_factor_authentication_enabled: true)
      totp_credential = TotpCredential.create!(user: user)

      post :two_factor_authentication, params: { user_id: user.external_id, enabled: false }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "user_id" => user.external_id,
        "message" => "Two-factor authentication disabled",
        "two_factor_authentication_enabled" => false
      )
      expect(user.reload.two_factor_authentication_enabled?).to be(false)
      expect(TotpCredential.where(id: totp_credential.id)).to be_empty
    end

    include_examples "requires user_id for user mutation", :two_factor_authentication, extra_params: { enabled: true }
    include_examples "supports user lookup by user_id", :two_factor_authentication, extra_params: { enabled: true }
    include_examples "checks expected_email for user mutation", :two_factor_authentication, extra_params: { enabled: true }
  end

  describe "POST create_comment" do
    let(:user) { create(:user) }
    let(:idempotency_key) { SecureRandom.uuid }

    include_examples "admin api authorization required", :post, :create_comment

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :create_comment, params: { content: "hi", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 400 when content is missing" do
      post :create_comment, params: { user_id: user.external_id, idempotency_key: idempotency_key }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "content is required" }.as_json)
    end

    it "returns 400 when idempotency_key is missing" do
      post :create_comment, params: { user_id: user.external_id, content: "hi" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "idempotency_key is required" }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :create_comment, params: { user_id: "missing", content: "hi", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "creates a comment attributed to GUMROAD_ADMIN_ID" do
      expect do
        post :create_comment, params: { user_id: user.external_id, content: "An admin note", idempotency_key: idempotency_key }
      end.to change { user.comments.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
      comment_data = response.parsed_body["comment"]
      expect(comment_data).to include(
        "content" => "An admin note",
        "comment_type" => Comment::COMMENT_TYPE_NOTE,
        "deleted_at" => nil,
        "alive" => true
      )
      expect(comment_data["id"]).to be_present
      expect(user.comments.last.author_id).to eq(admin_user.id)
    end

    it "creates comments and audit rows attributed to a per-actor token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      admin_api_token = AdminApiToken.find_by!(actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :create_comment, params: { user_id: user.external_id, content: "Actor note", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:ok)
      expect(user.comments.last).to have_attributes(
        author_id: actor.id,
        content: "Actor note"
      )
      expect(AdminApiAuditLog.last).to have_attributes(
        action: "users.create_comment",
        actor_user_id: actor.id,
        admin_api_token_id: admin_api_token.id,
        target_type: "User",
        target_id: user.id,
        response_status: 200
      )
    end

    it "returns the existing comment when called twice with the same key and matching content" do
      post :create_comment, params: { user_id: user.external_id, content: "Note", idempotency_key: idempotency_key }
      first_id = response.parsed_body["comment"]["id"]

      expect do
        post :create_comment, params: { user_id: user.external_id, content: "Note", idempotency_key: idempotency_key }
      end.not_to change { user.comments.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["comment"]["id"]).to eq(first_id)
    end

    it "returns 409 conflict when the same key is reused with different content" do
      post :create_comment, params: { user_id: user.external_id, content: "First", idempotency_key: idempotency_key }
      expect(response).to have_http_status(:ok)

      post :create_comment, params: { user_id: user.external_id, content: "Different", idempotency_key: idempotency_key }

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to eq({ success: false, message: "Idempotency key already used with different content" }.as_json)
    end

    it "returns 422 when the content fails validation" do
      post :create_comment, params: { user_id: user.external_id, content: "x" * 10_001, idempotency_key: idempotency_key }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
    end

    include_examples "requires user_id for user mutation", :create_comment, extra_params: { content: "via user_id", idempotency_key: SecureRandom.uuid }
    include_examples "supports user lookup by user_id", :create_comment, extra_params: { content: "via user_id", idempotency_key: SecureRandom.uuid }
    include_examples "checks expected_email for user mutation", :create_comment, extra_params: { content: "via user_id", idempotency_key: SecureRandom.uuid }
  end

  describe "POST mark_compliant" do
    let(:user) { create(:user, user_risk_state: "suspended_for_fraud", email: "seller@example.com") }

    include_examples "admin api authorization required", :post, :mark_compliant

    it "returns 400 when email is missing" do
      post :mark_compliant

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :mark_compliant, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "marks the user compliant and creates separate audit and note comments attributed to GUMROAD_ADMIN_ID" do
      expect do
        post :mark_compliant, params: { user_id: user.external_id, note: "Cleared after review" }
      end.to change { user.comments.reload.count }.by(2)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        user_id: user.external_id,
        status: "marked_compliant",
        message: "User marked compliant"
      }.as_json)
      expect(user.reload).to be_compliant

      audit_comment = user.comments.find_by!(comment_type: Comment::COMMENT_TYPE_COMPLIANT)
      expect(audit_comment).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_COMPLIANT
      )
      expect(audit_comment.content).to include("Marked compliant by")

      note = user.comments.find_by!(comment_type: Comment::COMMENT_TYPE_NOTE)
      expect(note).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content: "Cleared after review"
      )
    end

    it "returns 422 without marking the user compliant when the note is invalid" do
      expect do
        post :mark_compliant, params: { user_id: user.external_id, note: "x" * 10_001 }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("Content is too long")
      expect(user.reload).to be_suspended_for_fraud
    end

    it "keeps the existing sibling-account compliant side effect" do
      payment_address = "shared@example.com"
      user.update!(payment_address:)
      sibling = create(:user, user_risk_state: "suspended_for_fraud", payment_address:)

      post :mark_compliant, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(user.reload).to be_compliant
      expect(sibling.reload).to be_compliant
      expect(sibling.comments.last).to have_attributes(
        author_name: "enable_sellers_other_accounts",
        comment_type: Comment::COMMENT_TYPE_COMPLIANT
      )
      expect(sibling.comments.last.content).to include("payment address #{payment_address} is now unblocked")
    end

    it "returns success without creating another comment when the user is already compliant" do
      user.update!(user_risk_state: "compliant")

      expect do
        post :mark_compliant, params: { user_id: user.external_id, note: "Retry" }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        user_id: user.external_id,
        status: "already_compliant",
        message: "User is already compliant"
      }.as_json)
    end

    include_examples "requires user_id for user mutation", :mark_compliant
    include_examples "supports user lookup by user_id", :mark_compliant, build_user: -> { create(:user, user_risk_state: "suspended_for_fraud") }
    include_examples "checks expected_email for user mutation", :mark_compliant, build_user: -> { create(:user, user_risk_state: "suspended_for_fraud") }
  end

  describe "POST suspend_for_fraud" do
    let(:user) { create(:compliant_user, email: "seller@example.com") }

    include_examples "admin api authorization required", :post, :suspend_for_fraud

    it "returns 400 when email is missing" do
      post :suspend_for_fraud

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: user_id_required_message }.as_json)
    end

    it "returns 404 when the user does not exist" do
      post :suspend_for_fraud, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "suspends the user for fraud and creates an audit comment attributed to GUMROAD_ADMIN_ID" do
      expect do
        post :suspend_for_fraud, params: { user_id: user.external_id }
      end.to change { user.comments.reload.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        user_id: user.external_id,
        status: "suspended_for_fraud",
        message: "User suspended for fraud"
      }.as_json)
      expect(user.reload).to be_suspended_for_fraud

      comment = user.comments.last
      expect(comment).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_SUSPENDED
      )
      expect(comment.content).to include("Suspended for fraud")
    end

    it "creates an extra suspension note when one is provided" do
      expect do
        post :suspend_for_fraud, params: { user_id: user.external_id, suspension_note: "Chargeback risk confirmed" }
      end.to change { user.comments.reload.count }.by(2)

      expect(response).to have_http_status(:ok)
      note = user.comments.find_by!(comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE)
      expect(note).to have_attributes(
        author_id: admin_user.id,
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: "Chargeback risk confirmed"
      )
    end

    it "returns 422 without suspending the user when the suspension note is invalid" do
      expect do
        post :suspend_for_fraud, params: { user_id: user.external_id, suspension_note: "x" * 10_001 }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["message"]).to include("Content is too long")
      expect(user.reload).to be_compliant
    end

    it "returns success without creating another comment when the user is already suspended" do
      user.update!(user_risk_state: "suspended_for_fraud")

      expect do
        post :suspend_for_fraud, params: { user_id: user.external_id, suspension_note: "Retry" }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        user_id: user.external_id,
        status: "already_suspended",
        message: "User is already suspended for fraud"
      }.as_json)
    end

    it "returns 422 when the user is suspended for a different reason" do
      user.update!(user_risk_state: "suspended_for_tos_violation")

      expect do
        post :suspend_for_fraud, params: { user_id: user.external_id }
      end.not_to change { user.comments.reload.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(user.reload).to be_suspended_for_tos_violation
    end

    it "returns 422 when the state machine rejects the suspension" do
      user.update!(verified: true)

      post :suspend_for_fraud, params: { user_id: user.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
      expect(user.reload).to be_compliant
    end

    include_examples "requires user_id for user mutation", :suspend_for_fraud
    include_examples "supports user lookup by user_id", :suspend_for_fraud, build_user: -> { create(:compliant_user) }
    include_examples "checks expected_email for user mutation", :suspend_for_fraud, build_user: -> { create(:compliant_user) }
  end

  describe "POST watch" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :watch

    it "returns bad request when user_id is missing" do
      post :watch, params: { revenue_threshold: "200" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq(user_id_required_message)
    end

    it "returns bad request when revenue_threshold is missing" do
      post :watch, params: { user_id: user.external_id }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold is required")
    end

    it "returns bad request when revenue_threshold is not positive" do
      post :watch, params: { user_id: user.external_id, revenue_threshold: "0" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold must be a positive number")
    end

    it "returns bad request when revenue_threshold is non-finite" do
      ["Infinity", "-Infinity", "NaN"].each do |revenue_threshold|
        post :watch, params: { user_id: user.external_id, revenue_threshold: }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to eq("revenue_threshold must be a positive number")
      end
    end

    it "returns not found when user does not exist" do
      post :watch, params: { user_id: "missing", revenue_threshold: "200" }

      expect(response).to have_http_status(:not_found)
    end

    it "creates a watched user record" do
      expect do
        post :watch, params: { user_id: user.external_id, revenue_threshold: "200", notes: "Risk review: monitoring" }
      end.to change { WatchedUser.count }.by(1)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["user_id"]).to eq(user.external_id)
      expect(body["message"]).to eq("User added to watchlist")
      expect(body["watched_user"]["revenue_threshold_cents"]).to eq(20_000)
      expect(body["watched_user"]["notes"]).to eq("Risk review: monitoring")
    end

    it "returns 422 when user is already being watched" do
      create(:watched_user, user: user)

      post :watch, params: { user_id: user.external_id, revenue_threshold: "500" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("User is already being watched")
    end

    include_examples "requires user_id for user mutation", :watch, extra_params: { revenue_threshold: "200" }
    include_examples "supports user lookup by user_id", :watch, extra_params: { revenue_threshold: "200" }
    include_examples "checks expected_email for user mutation", :watch, extra_params: { revenue_threshold: "200" }
  end

  describe "POST unwatch" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :unwatch

    it "returns bad request when user_id is missing" do
      post :unwatch

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq(user_id_required_message)
    end

    it "returns not found when user does not exist" do
      post :unwatch, params: { user_id: "missing" }

      expect(response).to have_http_status(:not_found)
    end

    it "removes the user from the watchlist" do
      watched_user = create(:watched_user, user: user)

      post :unwatch, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
      expect(watched_user.reload.deleted_at).not_to be_nil
    end

    it "returns 422 when user is not being watched" do
      post :unwatch, params: { user_id: user.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("User is not currently being watched")
    end

    include_examples "requires user_id for user mutation", :unwatch
    include_examples "supports user lookup by user_id", :unwatch, build_user: -> { user = create(:user); create(:watched_user, user:); user }
    include_examples "checks expected_email for user mutation", :unwatch, build_user: -> { user = create(:user); create(:watched_user, user:); user }
  end

  describe "POST update_watch" do
    let(:user) { create(:user) }

    include_examples "admin api authorization required", :post, :update_watch

    it "returns bad request when user_id is missing" do
      post :update_watch, params: { revenue_threshold: "200" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq(user_id_required_message)
    end

    it "returns bad request when revenue_threshold is missing" do
      post :update_watch, params: { user_id: user.external_id }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold is required")
    end

    it "returns bad request when revenue_threshold is not positive" do
      create(:watched_user, user:)

      post :update_watch, params: { user_id: user.external_id, revenue_threshold: "0" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("revenue_threshold must be a positive number")
    end

    it "returns not found when user does not exist" do
      post :update_watch, params: { user_id: "missing", revenue_threshold: "200" }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 422 when user is not being watched" do
      post :update_watch, params: { user_id: user.external_id, revenue_threshold: "200" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("User is not currently being watched")
    end

    it "updates the active watched user" do
      watched_user = create(:watched_user, user:, revenue_threshold_cents: 20_000, notes: "Old notes")

      expect do
        post :update_watch, params: { user_id: user.external_id, revenue_threshold: "500", notes: "New notes" }
      end.not_to change { WatchedUser.count }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["user_id"]).to eq(user.external_id)
      expect(response.parsed_body["message"]).to eq("Watchlist updated")
      expect(response.parsed_body["watched_user"]["revenue_threshold_cents"]).to eq(50_000)
      expect(response.parsed_body["watched_user"]["notes"]).to eq("New notes")
      expect(watched_user.reload).to have_attributes(revenue_threshold_cents: 50_000, notes: "New notes")
    end

    it "preserves notes when notes is omitted" do
      watched_user = create(:watched_user, user:, notes: "Keep this")

      post :update_watch, params: { user_id: user.external_id, revenue_threshold: "300" }

      expect(response).to have_http_status(:ok)
      expect(watched_user.reload.notes).to eq("Keep this")
    end

    it "clears notes when notes is blank" do
      watched_user = create(:watched_user, user:, notes: "Clear this")

      post :update_watch, params: { user_id: user.external_id, revenue_threshold: "300", notes: "" }

      expect(response).to have_http_status(:ok)
      expect(watched_user.reload.notes).to be_nil
    end

    include_examples "requires user_id for user mutation", :update_watch, extra_params: { revenue_threshold: "200" }
    include_examples "supports user lookup by user_id", :update_watch,
                     build_user: -> { user = create(:user); create(:watched_user, user:); user },
                     extra_params: { revenue_threshold: "200" }
    include_examples "checks expected_email for user mutation", :update_watch,
                     build_user: -> { user = create(:user); create(:watched_user, user:); user },
                     extra_params: { revenue_threshold: "200" }
  end
end
