# frozen_string_literal: true

require "spec_helper"

describe Api::V2::RefundPoliciesController do
  let(:seller) { create(:user) }
  let(:app) { create(:oauth_application, owner: create(:user)) }

  describe "GET 'show'" do
    context "without a token" do
      it "returns 401" do
        get :show
        expect(response.status).to eq(401)
      end
    end

    context "with a valid token" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_public") }

      it "returns the current refund policy" do
        seller.refund_policy.update!(max_refund_period_in_days: 30, fine_print: "Refund requests are reviewed within 2 business days.")

        get :show, params: { access_token: token.token }

        expect(response.parsed_body).to eq(
          "success" => true,
          "refund_policy" => {
            "refund_period" => "30",
            "title" => "30-day money back guarantee",
            "fine_print" => "Refund requests are reviewed within 2 business days.",
            "in_effect" => true,
          }
        )
      end

      it "reports when the account-level refund policy is not in effect" do
        seller.update!(refund_policy_enabled: false)

        get :show, params: { access_token: token.token }

        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["refund_policy"]["in_effect"]).to be(false)
      end
    end
  end

  describe "PUT 'update'" do
    context "without a token" do
      it "returns 401" do
        put :update, params: { refund_period: "30" }
        expect(response.status).to eq(401)
      end
    end

    context "with a token missing edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "view_public view_sales") }

      it "returns 403" do
        put :update, params: { access_token: token.token, refund_period: "30" }
        expect(response.status).to eq(403)
      end
    end

    context "with edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "edit_products") }

      it "updates the refund period and fine print" do
        seller.refund_policy.update!(max_refund_period_in_days: 0)

        put :update, params: { access_token: token.token, refund_period: "30", fine_print: "Refund requests are reviewed within 2 business days." }

        refund_policy = seller.refund_policy.reload
        expect(refund_policy.max_refund_period_in_days).to eq(30)
        expect(refund_policy.fine_print).to eq("Refund requests are reviewed within 2 business days.")
        expect(response.parsed_body).to eq(
          "success" => true,
          "refund_policy" => {
            "refund_period" => "30",
            "title" => "30-day money back guarantee",
            "fine_print" => "Refund requests are reviewed within 2 business days.",
            "in_effect" => true,
          }
        )
      end

      it "updates the refund period to none" do
        seller.refund_policy.update!(max_refund_period_in_days: 30)

        put :update, params: { access_token: token.token, refund_period: "none" }

        expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(0)
        expect(response.parsed_body).to eq(
          "success" => true,
          "refund_policy" => {
            "refund_period" => "none",
            "title" => "No refunds allowed",
            "fine_print" => nil,
            "in_effect" => true,
          }
        )
      end

      it "rejects an invalid refund period with the allowed values" do
        seller.refund_policy.update!(max_refund_period_in_days: 30)

        put :update, params: { access_token: token.token, refund_period: "365" }

        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "Refund period must be one of: none, 7, 14, 30, 183."
        )
        expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(30)
      end

      it "rejects undocumented numeric zero as a refund period" do
        seller.refund_policy.update!(max_refund_period_in_days: 30)

        put :update, params: { access_token: token.token, refund_period: "0" }

        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "Refund period must be one of: none, 7, 14, 30, 183."
        )
        expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(30)
      end

      it "rejects a missing refund period" do
        seller.refund_policy.update!(max_refund_period_in_days: 30)

        put :update, params: { access_token: token.token }

        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "Refund period is required."
        )
        expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(30)
      end

      it "rejects fine print over 3000 characters" do
        seller.refund_policy.update!(max_refund_period_in_days: 30, fine_print: "Existing fine print")

        put :update, params: { access_token: token.token, refund_period: "14", fine_print: "a" * 3001 }

        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "Fine print is too long (maximum is 3000 characters)"
        )
        refund_policy = seller.refund_policy.reload
        expect(refund_policy.max_refund_period_in_days).to eq(30)
        expect(refund_policy.fine_print).to eq("Existing fine print")
      end

      it "strips HTML from fine print" do
        put :update, params: { access_token: token.token, refund_period: "14", fine_print: "<p>Refunds <strong>approved</strong></p>" }

        refund_policy = seller.refund_policy.reload
        expect(refund_policy.max_refund_period_in_days).to eq(14)
        expect(refund_policy.fine_print).to eq("Refunds approved")
        expect(response.parsed_body["refund_policy"]["fine_print"]).to eq("Refunds approved")
      end

      it "rejects updates when the account-level refund policy is not in effect" do
        seller.update!(refund_policy_enabled: false)
        seller.refund_policy.update!(max_refund_period_in_days: 30, fine_print: "Existing fine print")

        put :update, params: { access_token: token.token, refund_period: "7", fine_print: "Updated fine print" }

        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "The account-level refund policy is not in effect for this seller."
        )
        refund_policy = seller.refund_policy.reload
        expect(refund_policy.max_refund_period_in_days).to eq(30)
        expect(refund_policy.fine_print).to eq("Existing fine print")
      end
    end
  end
end
