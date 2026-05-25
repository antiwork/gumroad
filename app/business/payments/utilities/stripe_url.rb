# frozen_string_literal: true

module StripeUrl
  # Stripe dashboard workspace id for the Gumroad platform account; required as the
  # first path segment for deep links — Stripe redirects to the dashboard home otherwise.
  DASHBOARD_WORKSPACE_ID = "9e1RjUNIyYGpA9Cfh3RmQxxTzb1aakpE"

  def self.dashboard_url(account_id: nil)
    [base_url(account_id:), "dashboard"].join("/")
  end

  def self.event_url(event_id, account_id: nil)
    [base_url(account_id:), "events", event_id].join("/")
  end

  def self.transfer_url(transfer_id, account_id: nil)
    segments = ["https://dashboard.stripe.com", DASHBOARD_WORKSPACE_ID]
    segments += ["connect", "view-as", account_id] if account_id
    segments << "test" unless Rails.env.production?
    segments += ["payouts", transfer_id]
    segments.join("/")
  end

  def self.charge_url(charge_id)
    [base_url, "payments", charge_id].join("/")
  end

  def self.connected_account_url(account_id)
    [base_url, "applications", "users", account_id].join("/")
  end

  private_class_method
  def self.base_url(account_id: nil)
    [
      "https://dashboard.stripe.com",
      account_id,
      ("test" unless Rails.env.production?)
    ].compact.join("/")
  end
end
