# frozen_string_literal: true

# Ai::StoreAgentObjectFormatter turns the JSON the v2 API already returns into compact "display
# objects" the Agent chat renders inline as cards / a list view, instead of the model describing them
# in prose. Each display object is intentionally small and presentation-ready:
#
#   {
#     type:     "product" | "discount" | "sale" | "payout" | "email" | "upsell" | "object",
#     title:    String,                      # headline (product name, discount code, ...)
#     subtitle: String | nil,                # one-line secondary (price, amount off, ...)
#     fields:   [{ label:, value: }, ...],   # a few key/value rows for a definition list
#     url:      String | nil,                # canonical link -> "Open" in a new tab
#     copy:     String | nil,                # the most useful thing to copy (the url, or an id)
#   }
#
# We only surface fields the API already exposes for this seller, so this can never leak more than
# the endpoint itself returns. Unknown shapes fall back to a generic object so nothing crashes; the
# model's prose still carries the answer even when we can't build a rich card.
module Ai::StoreAgentObjectFormatter
  module_function

  # Pull display objects out of one API response for a given catalog endpoint.
  # @param endpoint [Ai::StoreAgentApiCatalog::Endpoint]
  # @param response [Hash] parsed JSON body from StoreAgentApiClient
  # @return [Array<Hash>] zero or more display objects
  def from_response(endpoint, response)
    return [] unless response.is_a?(Hash)
    # Never build cards from an error envelope.
    return [] if response["success"] == false

    case endpoint.id
    when "list_products"
      Array(response["products"]).filter_map { |p| product(p) }
    when "get_product", "create_product", "update_product", "enable_product", "disable_product"
      [product(response["product"] || response)].compact
    when "list_offer_codes"
      Array(response["offer_codes"] || response["products"]).filter_map { |o| discount(o) }
    when "get_offer_code", "create_offer_code", "update_offer_code"
      [discount(response["offer_code"] || response)].compact
    when "list_sales"
      Array(response["sales"]).filter_map { |s| sale(s) }
    when "get_sale", "refund_sale", "mark_sale_as_shipped"
      [sale(response["sale"] || response)].compact
    when "list_payouts"
      Array(response["payouts"]).filter_map { |p| payout(p) }
    when "get_payout", "upcoming_payout"
      [payout(response["payout"] || response)].compact
    when "list_upsells"
      Array(response["upsells"]).filter_map { |u| upsell(u) }
    when "get_upsell", "create_upsell", "update_upsell"
      [upsell(response["upsell"] || response)].compact
    when "list_emails"
      Array(response["emails"] || response["installments"]).filter_map { |e| email(e) }
    when "get_email", "create_email"
      [email(response["email"] || response["installment"] || response)].compact
    else
      []
    end
  end

  # ---- per-type builders (all tolerant of missing keys) ----

  def product(json)
    return nil unless json.is_a?(Hash) && (json["name"] || json["id"])
    url = json["short_url"].presence || json["landing_url"].presence
    {
      type: "product",
      title: json["name"].to_s,
      subtitle: json["formatted_price"].presence || money(json["price"], json["currency"]),
      fields: compact_fields([
                               ["Status", json.key?("published") ? (json["published"] ? "Published" : "Unpublished") : nil],
                               ["Sales", json["sales_count"]],
                               ["Price", json["formatted_price"].presence || money(json["price"], json["currency"])],
                             ]),
      url:,
      copy: url.presence || json["id"],
    }
  end

  def discount(json)
    return nil unless json.is_a?(Hash) && (json["name"] || json["id"])
    amount = json["percent_off"].present? ? "#{json['percent_off']}% off" : (json["amount_cents"].present? ? "#{money(json['amount_cents'])} off" : nil)
    {
      type: "discount",
      title: json["name"].to_s, # the API returns the code as `name`
      subtitle: amount,
      fields: compact_fields([
                               ["Amount", amount],
                               ["Applies to", json["universal"] ? "All products" : "Selected products"],
                               ["Times used", json["times_used"]],
                               ["Max uses", json["max_purchase_count"]],
                             ]),
      url: nil,
      copy: json["name"].presence || json["id"], # the code is the useful thing to copy
    }
  end

  def sale(json)
    return nil unless json.is_a?(Hash) && json["id"]
    {
      type: "sale",
      title: json["product_name"].presence || json["email"].presence || "Sale #{json['id']}",
      subtitle: json["formatted_total_price"].presence || money(json["price"], json["currency"]),
      fields: compact_fields([
                               ["Buyer", json["email"]],
                               ["Product", json["product_name"]],
                               ["Amount", json["formatted_total_price"].presence || money(json["price"], json["currency"])],
                               ["Date", json["created_at"]],
                               ["Refunded", json.key?("refunded") ? (json["refunded"] ? "Yes" : "No") : nil],
                             ]),
      url: nil,
      copy: json["id"],
    }
  end

  def payout(json)
    return nil unless json.is_a?(Hash) && (json["id"] || json["amount"] || json["amount_cents"])
    amount = json["displayable_amount"].presence || money(json["amount_cents"] || json["amount"], json["currency"])
    {
      type: "payout",
      title: amount.presence || "Payout",
      subtitle: json["status"].presence,
      fields: compact_fields([
                               ["Amount", amount],
                               ["Status", json["status"]],
                               ["Paid on", json["paid_at"].presence || json["created_at"]],
                             ]),
      url: nil,
      copy: json["id"],
    }
  end

  def upsell(json)
    return nil unless json.is_a?(Hash) && (json["name"] || json["id"])
    {
      type: "upsell",
      title: json["name"].to_s,
      subtitle: json["cross_sell"] ? "Cross-sell" : "Upsell",
      fields: compact_fields([
                               ["Type", json["cross_sell"] ? "Cross-sell" : "Upsell"],
                               ["Discount", json["offer_code"].is_a?(Hash) ? json.dig("offer_code", "name") : json["offer_code"]],
                             ]),
      url: nil,
      copy: json["id"],
    }
  end

  def email(json)
    return nil unless json.is_a?(Hash) && (json["subject"] || json["name"] || json["id"])
    {
      type: "email",
      title: json["subject"].presence || json["name"].to_s,
      subtitle: json.key?("published") ? (json["published"] ? "Sent" : "Draft") : nil,
      fields: compact_fields([
                               ["Status", json.key?("published") ? (json["published"] ? "Sent" : "Draft") : nil],
                               ["Audience", json["audience_type"]],
                               ["Published", json["published_at"]],
                             ]),
      url: json["published_url"].presence,
      copy: json["published_url"].presence || json["id"],
    }
  end

  # ---- helpers ----

  def compact_fields(pairs)
    pairs.filter_map do |label, value|
      next if value.nil?
      str = value.to_s.strip
      next if str.empty?
      { label:, value: str }
    end
  end

  # Format integer cents into a plain dollar string. We don't know every currency's symbol here, so
  # default to "$" for USD and a "<amount> <CCY>" form otherwise; the API's own formatted_* fields are
  # preferred wherever present.
  def money(cents, currency = nil)
    return nil if cents.nil?
    n = cents.to_i
    dollars = format("%.2f", n / 100.0).sub(/\.00$/, "")
    ccy = (currency || "usd").to_s.downcase
    ccy == "usd" ? "$#{dollars}" : "#{dollars} #{ccy.upcase}"
  end
end
