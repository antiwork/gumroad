# frozen_string_literal: true

require "spec_helper"

describe "legacy internal helper admin routes" do
  def route_for(path, method)
    Rails.application.routes.recognize_path("https://#{API_DOMAIN}#{path}", method:)
  end

  [
    [:post, "/internal/helper/users/create_appeal", "api/internal/helper/users", "create_appeal"],
    [:post, "/internal/helper/users/create_comment", "api/internal/helper/users", "create_comment"],
    [:post, "/internal/helper/users/user_suspension_info", "api/internal/helper/users", "user_suspension_info"],
    [:post, "/internal/helper/users/send_reset_password_instructions", "api/internal/helper/users", "send_reset_password_instructions"],
    [:post, "/internal/helper/users/update_email", "api/internal/helper/users", "update_email"],
    [:post, "/internal/helper/users/update_two_factor_authentication_enabled", "api/internal/helper/users", "update_two_factor_authentication_enabled"],
    [:post, "/internal/helper/purchases/refund_last_purchase", "api/internal/helper/purchases", "refund_last_purchase"],
    [:post, "/internal/helper/purchases/resend_last_receipt", "api/internal/helper/purchases", "resend_last_receipt"],
    [:post, "/internal/helper/purchases/resend_all_receipts", "api/internal/helper/purchases", "resend_all_receipts"],
    [:post, "/internal/helper/purchases/resend_receipt_by_number", "api/internal/helper/purchases", "resend_receipt_by_number"],
    [:post, "/internal/helper/purchases/search", "api/internal/helper/purchases", "search"],
    [:post, "/internal/helper/purchases/reassign_purchases", "api/internal/helper/purchases", "reassign_purchases"],
    [:post, "/internal/helper/purchases/auto_refund_purchase", "api/internal/helper/purchases", "auto_refund_purchase"],
    [:post, "/internal/helper/purchases/refund_taxes_only", "api/internal/helper/purchases", "refund_taxes_only"],
    [:get, "/internal/helper/payouts", "api/internal/helper/payouts", "index"],
    [:post, "/internal/helper/payouts", "api/internal/helper/payouts", "create"],
    [:get, "/internal/helper/instant_payouts", "api/internal/helper/instant_payouts", "index"],
    [:post, "/internal/helper/instant_payouts", "api/internal/helper/instant_payouts", "create"],
  ].each do |method, path, controller, action|
    it "routes #{method.to_s.upcase} #{path}" do
      expect(route_for(path, method)).to include(controller:, action:)
    end
  end
end
