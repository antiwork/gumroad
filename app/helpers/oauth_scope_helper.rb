# frozen_string_literal: true

module OauthScopeHelper
  DESCRIPTIONS = {
    "account" => "Full access to your account.",
    "creator_api" => "Creator API",
    "edit_emails" => "Create and manage your audience emails.",
    "edit_products" => "Create new products and edit your existing products.",
    "edit_profile" => "Edit your profile name and bio.",
    "edit_sales" => "Refund your sales, revoke or restore buyer access, and resend purchase receipts to customers.",
    "helper_api" => "Helper API",
    "ifttt" => "See your sales data.",
    "mark_sales_as_shipped" => "Mark your sales as shipped.",
    "mobile_api" => "Mobile API",
    "partner_api" => "Link your Gumroad account to your account on this application. It can then list your published products and send you products to import, which you confirm first.",
    "refund_sales" => "Refund your sales.",
    "revenue_share" => "Revenue Share",
    "unfurl" => "Fetch public information of any product to preview it in Notion.",
    "view_payouts" => "See your payouts data.",
    "view_library" => "See the products you bought.",
    "view_profile" => "See your profile data.",
    "view_public" => "See your public information (name, bio).",
    "view_sales" => "See your sales data.",
    "view_tax_data" => "See your tax forms and annual earnings summary."
  }.freeze

  # The consent pages name the account they authorize, so the scope list has to name it too:
  # "edit your existing products" reads as the signed-in user's own account otherwise.
  def oauth_scope_description(scope, account_name: nil)
    description = DESCRIPTIONS[scope.to_s]
    return description if description.blank? || account_name.blank?

    description.gsub(/\byour\b/) { "#{account_name}'s" }
  end
end
