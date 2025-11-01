# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::UsersController, type: :controller do
  let(:admin_user) { create(:user, :admin) }
  let(:regular_user) { create(:user, email: "buyer@example.com") }

  before do
    sign_in admin_user
  end

  describe "GET #show" do
    let(:user) do
      create(:user,
        email: "seller@example.com",
        name: "Test Seller",
        username: "testseller",
        verified: true,
        bio: "This is my bio")
    end

    context "when user exists" do
      it "returns inertia response with correct component" do
        get :show, params: { id: user.id }

        expect(response).to have_http_status(:ok)
        expect_inertia.to render_component("Admin/Users/Show")
      end

      it "passes all required user props" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props(
          "user.id" => user.id,
          "user.external_id" => user.external_id,
          "user.email" => user.email,
          "user.username" => user.username,
          "user.name" => user.name,
          "user.verified" => true,
          "user.bio" => user.bio
        )
      end

      it "serializes dates to ISO8601 format" do
        get :show, params: { id: user.id }

        user_props = controller.view_assigns["inertia_props"]["user"]
        expect(user_props["created_at"]).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        expect(user_props["updated_at"]).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        expect(user_props["created_at"]).to eq(user.created_at.iso8601)
        expect(user_props["updated_at"]).to eq(user.updated_at.iso8601)
      end

      it "excludes sensitive data from user props" do
        get :show, params: { id: user.id }

        user_props = controller.view_assigns["inertia_props"]["user"]
        expect(user_props).not_to have_key("password_digest")
        expect(user_props).not_to have_key("encrypted_password")
        expect(user_props).not_to have_key("password")
        expect(user_props).not_to have_key("reset_password_token")
        expect(user_props).not_to have_key("api_key")
      end

      it "includes pagination props" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props(
          "pagy.page",
          "pagy.pages",
          "pagy.count"
        )
      end

      it "includes products array" do
        create_list(:link, 3, user: user)

        get :show, params: { id: user.id }

        products = controller.view_assigns["inertia_props"]["products"]
        expect(products).to be_an(Array)
        expect(products.length).to eq(3)
      end

      it "serializes product data correctly" do
        product = create(:link, user: user, name: "Test Product")

        get :show, params: { id: user.id }

        products = controller.view_assigns["inertia_props"]["products"]
        product_data = products.first

        expect(product_data["id"]).to eq(product.id)
        expect(product_data["name"]).to eq("Test Product")
        expect(product_data["unique_permalink"]).to eq(product.unique_permalink)
        expect(product_data["created_at"]).to eq(product.created_at.iso8601)
      end

      it "includes is_affiliate_user flag" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("is_affiliate_user" => false)
      end

      it "includes empty user_memberships for user without teams" do
        get :show, params: { id: user.id }

        memberships = controller.view_assigns["inertia_props"]["user_memberships"]
        expect(memberships).to eq([])
      end

      it "includes user_memberships for user with team access" do
        seller = create(:user, email: "teamowner@example.com")
        membership = create(:team_membership,
          user: user,
          seller: seller,
          role: "admin")

        get :show, params: { id: user.id }

        memberships = controller.view_assigns["inertia_props"]["user_memberships"]
        expect(memberships.length).to eq(1)
        expect(memberships.first["seller_id"]).to eq(seller.id)
        expect(memberships.first["role"]).to eq("admin")
      end

      it "includes merchant_accounts" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("merchant_accounts")
      end

      it "includes compliance_info as nil when not present" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("compliance_info" => nil)
      end

      it "includes compliance_info when present" do
        compliance = create(:user_compliance_info,
          user: user,
          first_name: "Test",
          last_name: "User",
          is_business: false)

        get :show, params: { id: user.id }

        compliance_props = controller.view_assigns["inertia_props"]["compliance_info"]
        expect(compliance_props).not_to be_nil
        expect(compliance_props["first_name"]).to eq("Test")
        expect(compliance_props["last_name"]).to eq("User")
        expect(compliance_props["is_business"]).to eq(false)
      end

      it "excludes actual tax IDs from compliance info" do
        compliance = create(:user_compliance_info,
          user: user,
          individual_tax_id: "123-45-6789")

        get :show, params: { id: user.id }

        compliance_props = controller.view_assigns["inertia_props"]["compliance_info"]
        expect(compliance_props).not_to have_key("individual_tax_id")
        expect(compliance_props["individual_tax_id_provided"]).to eq(true)
      end

      it "includes comments with author information" do
        comment = create(:comment,
          commentable: user,
          author: admin_user,
          content: "Test comment")

        get :show, params: { id: user.id }

        comments = controller.view_assigns["inertia_props"]["comments"]
        expect(comments.length).to eq(1)
        expect(comments.first["content"]).to eq("Test comment")
        expect(comments.first["author_name"]).to be_present
      end

      it "includes email_versions" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("email_versions")
      end

      it "includes stripe_account_exists flag" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("stripe_account_exists" => false)
      end

      it "includes manual_payout_eligible flag" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("manual_payout_eligible")
      end

      it "includes currency when stripe account exists" do
        merchant_account = create(:merchant_account,
          user: user,
          charge_processor_id: StripeChargeProcessor.charge_processor_id,
          currency: "usd")
        allow(user).to receive(:stripe_account).and_return(merchant_account)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("currency" => "usd")
      end
    end

    context "when finding user by email" do
      it "finds user by email address" do
        get :show, params: { id: user.email }

        expect(response).to have_http_status(:ok)
        expect_inertia.to include_props("user.id" => user.id)
      end
    end

    context "when finding user by username" do
      it "finds user by username" do
        get :show, params: { id: user.username }

        expect(response).to have_http_status(:ok)
        expect_inertia.to include_props("user.id" => user.id)
      end
    end

    context "with suspended user" do
      let(:suspended_user) do
        create(:user,
          email: "suspended@example.com",
          user_risk_state: "suspended_for_fraud")
      end

      it "returns suspended user data" do
        get :show, params: { id: suspended_user.id }

        expect(response).to have_http_status(:ok)
        expect_inertia.to include_props(
          "user.user_risk_state" => "suspended_for_fraud"
        )
      end

      it "includes suspension reason if available" do
        suspended_user.update(tos_violation_reason: "Fraud detected")

        get :show, params: { id: suspended_user.id }

        expect_inertia.to include_props(
          "user.tos_violation_reason" => "Fraud detected"
        )
      end

      it "excludes post URLs for suspended users" do
        post = create(:post, user: suspended_user)

        get :show, params: { id: suspended_user.id }

        posts = controller.view_assigns["inertia_props"]["last_posts"]
        expect(posts).to be_an(Array)
        posts.each do |post_data|
          expect(post_data["url"]).to be_nil
        end
      end
    end

    context "with deleted user" do
      let(:deleted_user) do
        create(:user,
          email: "deleted@example.com",
          deleted_at: 1.day.ago)
      end

      it "returns deleted user data" do
        get :show, params: { id: deleted_user.id }

        expect(response).to have_http_status(:ok)
        expect_inertia.to include_props("user.id" => deleted_user.id)
      end

      it "includes deleted_at timestamp in ISO8601" do
        get :show, params: { id: deleted_user.id }

        user_props = controller.view_assigns["inertia_props"]["user"]
        expect(user_props["deleted_at"]).to eq(deleted_user.deleted_at.iso8601)
      end

      it "sets can_impersonate to false for deleted user" do
        get :show, params: { id: deleted_user.id }

        expect_inertia.to include_props("user.can_impersonate" => false)
      end
    end

    context "with user with verified status" do
      it "returns verified true for verified users" do
        user.update!(verified: true)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.verified" => true)
      end

      it "returns verified false for unverified users" do
        user.update!(verified: false)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.verified" => false)
      end
    end

    context "with user with custom fee" do
      it "includes custom_fee_per_thousand" do
        user.update!(custom_fee_per_thousand: 50)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.custom_fee_per_thousand" => 50)
      end

      it "includes null for no custom fee" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.custom_fee_per_thousand" => nil)
      end
    end

    context "with pagination" do
      it "paginates products correctly" do
        create_list(:link, 15, user: user)

        get :show, params: { id: user.id, page: 1 }

        pagy = controller.view_assigns["inertia_props"]["pagy"]
        products = controller.view_assigns["inertia_props"]["products"]

        expect(pagy["page"]).to eq(1)
        expect(pagy["pages"]).to eq(2)
        expect(products.length).to eq(10)
      end

      it "returns second page of products" do
        create_list(:link, 15, user: user)

        get :show, params: { id: user.id, page: 2 }

        pagy = controller.view_assigns["inertia_props"]["pagy"]
        products = controller.view_assigns["inertia_props"]["products"]

        expect(pagy["page"]).to eq(2)
        expect(products.length).to eq(5)
      end

      it "includes prev and next page numbers" do
        create_list(:link, 25, user: user)

        get :show, params: { id: user.id, page: 2 }

        pagy = controller.view_assigns["inertia_props"]["pagy"]
        expect(pagy["prev"]).to eq(1)
        expect(pagy["next"]).to eq(3)
      end
    end

    context "with bank account" do
      let(:bank_account) do
        create(:bank_account,
          user: user,
          account_holder_full_name: "Test User")
      end

      it "includes bank account data" do
        allow(user).to receive(:active_bank_account).and_return(bank_account)

        get :show, params: { id: user.id }

        bank_props = controller.view_assigns["inertia_props"]["active_bank_account"]
        expect(bank_props).not_to be_nil
        expect(bank_props["account_holder_full_name"]).to eq("Test User")
      end

      it "excludes sensitive bank account details" do
        allow(user).to receive(:active_bank_account).and_return(bank_account)

        get :show, params: { id: user.id }

        bank_props = controller.view_assigns["inertia_props"]["active_bank_account"]
        expect(bank_props).not_to have_key("account_number")
        expect(bank_props).not_to have_key("routing_number")
      end
    end

    context "authorization" do
      it "denies access to non-admin users" do
        sign_out admin_user
        sign_in regular_user

        get :show, params: { id: user.id }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(root_path)
      end

      it "denies access to unauthenticated users" do
        sign_out admin_user

        get :show, params: { id: user.id }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(login_path(next: admin_user_path(user)))
      end

      it "allows access to admin users" do
        get :show, params: { id: user.id }

        expect(response).to have_http_status(:ok)
      end

      it "allows access to team members" do
        team_member = create(:user, :team_member, email: "team@example.com")
        sign_in team_member

        get :show, params: { id: user.id }

        expect(response).to have_http_status(:ok)
      end
    end

    context "error handling" do
      it "returns 404 for non-existent user ID" do
        expect do
          get :show, params: { id: 999_999 }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns 404 for non-existent email" do
        expect do
          get :show, params: { id: "nonexistent@example.com" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns 404 for non-existent username" do
        expect do
          get :show, params: { id: "nonexistentuser" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "with user statistics" do
      it "includes has_payments flag when user has payments" do
        create(:payment, user: user)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.has_payments" => true)
      end

      it "includes has_payments false when user has no payments" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.has_payments" => false)
      end

      it "includes unpaid_balance_cents" do
        user.update!(unpaid_balance_cents: 10_000)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.unpaid_balance_cents" => 10_000)
      end
    end

    context "with payout data" do
      it "includes payouts_paused_by_source" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: "admin")

        get :show, params: { id: user.id }

        user_props = controller.view_assigns["inertia_props"]["user"]
        expect(user_props["payouts_paused_by_source"]).to eq("admin")
      end

      it "includes null for payouts_paused_for_reason when no reason" do
        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.payouts_paused_for_reason" => nil)
      end
    end

    context "with all_adult_products flag" do
      it "includes all_adult_products true" do
        user.update!(all_adult_products: true)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.all_adult_products" => true)
      end

      it "includes all_adult_products false" do
        user.update!(all_adult_products: false)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.all_adult_products" => false)
      end
    end

    context "with disable_paypal_sales flag" do
      it "includes disable_paypal_sales true" do
        user.update!(disable_paypal_sales: true)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.disable_paypal_sales" => true)
      end

      it "includes disable_paypal_sales false" do
        user.update!(disable_paypal_sales: false)

        get :show, params: { id: user.id }

        expect_inertia.to include_props("user.disable_paypal_sales" => false)
      end
    end

    context "with subdomain" do
      it "includes subdomain_with_protocol" do
        user.update!(username: "myshop")

        get :show, params: { id: user.id }

        user_props = controller.view_assigns["inertia_props"]["user"]
        expect(user_props["subdomain_with_protocol"]).to include(user.username)
      end
    end

    context "with user risk states" do
      %w[
        not_reviewed
        compliant
        flagged_for_fraud
        suspended_for_fraud
        flagged_for_tos_violation
        suspended_for_tos_violation
        on_probation
      ].each do |risk_state|
        it "handles #{risk_state} risk state" do
          user.update!(user_risk_state: risk_state)

          get :show, params: { id: user.id }

          expect_inertia.to include_props("user.user_risk_state" => risk_state)
        end
      end
    end

    context "with impersonate permission" do
      it "sets can_impersonate true when allowed" do
        get :show, params: { id: user.id }

        user_props = controller.view_assigns["inertia_props"]["user"]
        expect(user_props["can_impersonate"]).to be_in([true, false])
      end

      it "sets can_impersonate false for team members" do
        team_member = create(:user, :team_member, email: "member@example.com")

        get :show, params: { id: team_member.id }

        expect_inertia.to include_props("user.can_impersonate" => false)
      end
    end

    context "performance" do
      it "avoids N+1 queries for comments" do
        create_list(:comment, 5, commentable: user, author: admin_user)

        expect do
          get :show, params: { id: user.id }
        end.not_to exceed_query_limit(20)
      end
    end
  end
end



