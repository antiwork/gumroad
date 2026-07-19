# frozen_string_literal: true

# Ai::StoreAgentApiCatalog is the single declarative source of truth for every Gumroad public v2 API
# endpoint the store agent can drive. Each entry maps a stable `id` (the name the LLM uses) to the
# real HTTP method + path of the documented public API, so the agent reaches the FULL API surface
# through two generic tools (api_read / api_write) instead of dozens of hand-coded ones.
#
# Why a catalog instead of bespoke tools:
#   - Coverage: adding an endpoint is one row here, not a new tool + executor branch + schema.
#   - Safety: the agent can only ever call an `id` that exists in this list. Path templates fix the
#     shape of the URL, so the LLM fills in :placeholders (ids) and params — it can't synthesize an
#     arbitrary path. Reads (read: true) auto-run; everything else is a write that must be confirmed.
#   - Fidelity: each call is replayed against the real controller (see StoreAgentApiClient), so the
#     endpoint's own Doorkeeper scope check, Pundit/role authorization, validation, and JSON
#     serialization are reused verbatim. The agent can never exceed what the creator's own API token
#     could do.
#
# Path templates use :name placeholders filled from the tool call's `path_params`. `params` lists the
# query (reads) or body (writes) keys the endpoint accepts. For writes this list is load-bearing: a
# proposed body carrying a key not listed here is refused (see StoreAgentService and
# StoreAgentActionExecutor), because the v2 API silently ignores unknown body keys — a misnamed key
# (e.g. `price_cents` instead of `price`) would otherwise drop the value the model meant to send and
# fail downstream with a confusing error. The list is a deliberately curated subset of what each
# endpoint can accept: it is exactly what the system-prompt manifest teaches the model, so the agent
# only drives the surface it was told about.
module Ai::StoreAgentApiCatalog
  Endpoint = Struct.new(:id, :method, :path, :read, :scope, :admin_only, :summary, :path_params, :params, keyword_init: true) do
    def read? = read == true
    def write? = !read?

    # True if this endpoint may only be driven by an owner/admin (not a marketing member), even
    # though the underlying v2 endpoint's scope (e.g. view_sales) is broader. Used for capabilities
    # the dashboard restricts to admins beyond what the OAuth scope implies — e.g. webhook/resource
    # subscription management, which is OAuth-app management and admin-only in the dashboard.
    def admin_only? = admin_only == true

    # Expand the path template against a hash of path params. Ids are opaque external ids that never
    # legitimately contain a slash or dot-segment, so we REJECT any value with a path separator or
    # traversal segment. This is a security boundary, not cosmetics: the value is interpolated into
    # the routed v2 path AFTER the catalog/scope authorization check, so an unescaped "/" or ".."
    # could re-route a call authorized as (say) an edit_products product write to a different, more
    # weakly-scoped endpoint. Raise on a missing or path-bearing value so a malformed/abusive call
    # fails loudly rather than hitting the wrong URL.
    def expand_path(path_params)
      pp = (path_params || {}).transform_keys(&:to_s)
      path.gsub(/:([a-z_]+)/) do
        key = Regexp.last_match(1)
        value = pp[key].to_s.strip
        raise ArgumentError, "Missing path parameter :#{key}" if value.blank?
        # Disallow anything that could alter the routed path: separators, traversal, or percent/
        # backslash escapes that could decode to them. External ids are [A-Za-z0-9_-] in practice.
        if value.match?(%r{[/\\]}) || value.include?("..") || value.include?("%")
          raise ArgumentError, "Invalid path parameter :#{key}"
        end
        # Percent-encode the value before it is spliced into the URL. LLM-proposed ids sometimes
        # carry stray non-ASCII characters (e.g. "GJs2આ"), and Ruby's URI.parse — which rack-test
        # runs on the internal request path — raises URI::InvalidURIError on any non-ASCII URI,
        # turning a merely-wrong id into a 500 at confirm time (gumroad-private#1054). Encoded,
        # the request routes normally and the API answers with its own clean "not found" message.
        # Encoding happens AFTER the validations above so their view of the raw value is unchanged.
        ERB::Util.url_encode(value)
      end
    end

    # The proposal body keys that this endpoint does not declare in `params`. The v2 API ignores
    # body keys it doesn't read, so an undeclared key (e.g. `price_cents` instead of the declared
    # `price` on create_product) would silently drop the value the model meant to send — the call
    # then fails downstream with a confusing validation error. Both the propose path (service) and
    # the confirm path (executor) refuse such bodies up front using this list.
    def unknown_param_keys(body)
      (body || {}).keys.map(&:to_s) - params
    end

    # The corrective message for a body carrying undeclared keys, or nil when the body is fine.
    # Names both the bad keys and the accepted keys so the model (propose path) can immediately
    # retry with the right ones — a bare "invalid params" would leave it guessing. Lives here so
    # the propose path (StoreAgentService) and confirm path (StoreAgentActionExecutor) can't drift.
    def unknown_param_keys_error(body)
      unknown = unknown_param_keys(body)
      return nil if unknown.empty?

      accepted = params.any? ? "this endpoint accepts: #{params.join(', ')}" : "this endpoint accepts no params"
      "Unknown param#{"s" if unknown.size > 1} #{unknown.join(', ')} for #{id}; #{accepted}."
    end
  end

  # Build one endpoint row. read defaults to false (i.e. a write that must be confirmed).
  def self.ep(id, method, path, summary, read: false, scope: nil, admin_only: false, path_params: [], params: [])
    Endpoint.new(id:, method:, path:, read:, scope:, admin_only:, summary:, path_params:, params:)
  end

  ENDPOINTS = [
    # ---- Account / profile ----
    ep("get_user", :get, "/user", "Get the creator's own account: name, email, currency, profile url, bio.", read: true, scope: "view_profile"),
    ep("update_user", :patch, "/user", "Update the creator's profile fields (name, bio).", scope: "edit_profile",
                                                                                           params: %w[name bio]),
    ep("get_user_custom_html", :get, "/user/custom_html", "Get the creator's profile custom HTML.", read: true, scope: "view_profile"),
    ep("update_user_custom_html", :patch, "/user/custom_html", "Replace the creator's ENTIRE profile custom HTML with a new page. Destructive: anything not included in custom_html is lost. Only use this to author a brand-new page; to change part of an existing page, use edit_user_custom_html.", scope: "edit_profile", params: %w[custom_html]),
    ep("edit_user_custom_html", :post, "/user/custom_html/edit", "Make a targeted edit to the creator's existing profile custom HTML: replaces one exact snippet (find) with new HTML (replace) and leaves the rest of the page untouched. find must match the current HTML exactly once — include enough surrounding context. Always prefer this over update_user_custom_html when a page already exists.", scope: "edit_profile", params: %w[find replace]),

    # ---- Public media library ----
    # The creator's hosted image files. These are the ONLY file URLs that render on
    # custom HTML pages: the page sandbox's CSP restricts img/media sources to Gumroad's own CDN
    # hosts, so an off-platform URL displays as a broken image. To place a creator's image on a
    # page: upload_media with the image's URL, then embed the returned `url` in the page HTML.
    ep("list_media", :get, "/media", "List the creator's uploaded image files with their hosted urls. Only these hosted urls display on custom HTML pages — external image urls are blocked by the page's security policy.", read: true, scope: "view_profile"),
    ep("upload_media", :post, "/media", "Upload an image file to the creator's media library by giving the file's public url; Gumroad downloads and hosts it. Use this whenever the creator wants their image (logo, photo, banner) shown on their page: upload first, then embed the returned hosted url in the page HTML. Optional name labels the file in their library.", scope: "edit_profile", params: %w[url name]),
    ep("delete_media", :delete, "/media/:id", "Delete a file from the creator's media library. Its hosted url stops working, so remove it from any page that embeds it.", scope: "edit_profile", path_params: %w[id]),
    ep("get_categories", :get, "/categories", "List the product categories Gumroad supports.", read: true),
    ep("get_refund_policy", :get, "/refund_policy", "Get the creator's account-level refund policy.", read: true, scope: "view_profile"),
    # Account-level refund policy is changed via Settings in the dashboard, which is owner-only
    # (Settings::Main::UserPolicy#update?). Gate admin_only so a marketing member can't change refund
    # terms through the agent that they can't change in the dashboard.
    ep("update_refund_policy", :put, "/refund_policy", "Update the creator's account-level refund policy.", scope: "edit_products", admin_only: true,
                                                                                                            params: %w[refund_period fine_print]),

    # ---- Products ----
    ep("list_products", :get, "/products", "List the creator's products with price, status, and stats. Returns 10 per page, newest first; when the response includes next_page_key, pass it back as page_key to fetch the next page.", read: true, scope: "view_sales",
                                                                                                                                                                                                                                       params: %w[page_key]),
    ep("get_product", :get, "/products/:id", "Get one product by its id.", read: true, scope: "view_sales", path_params: %w[id]),
    ep("create_product", :post, "/products", "Create a new product.", scope: "edit_products",
                                                                      params: %w[name price description custom_permalink price_currency_type max_purchase_count]),
    ep("update_product", :put, "/products/:id", "Update a product's fields (name, price, description, etc.).", scope: "edit_products",
                                                                                                               path_params: %w[id], params: %w[name price description custom_permalink price_currency_type max_purchase_count]),
    ep("delete_product", :delete, "/products/:id", "Delete a product permanently.", scope: "edit_products", path_params: %w[id]),
    ep("enable_product", :put, "/products/:id/enable", "Publish a product so it is available for sale.", scope: "edit_products", path_params: %w[id]),
    ep("disable_product", :put, "/products/:id/disable", "Unpublish a product so it is no longer for sale.", scope: "edit_products", path_params: %w[id]),

    # ---- Custom fields (per product) ----
    ep("list_custom_fields", :get, "/products/:link_id/custom_fields", "List a product's custom fields.", read: true, scope: "view_sales", path_params: %w[link_id]),
    ep("create_custom_field", :post, "/products/:link_id/custom_fields", "Add a custom field to a product.", scope: "edit_products",
                                                                                                             path_params: %w[link_id], params: %w[name required type]),
    ep("update_custom_field", :put, "/products/:link_id/custom_fields/:id", "Update a product custom field.", scope: "edit_products",
                                                                                                              path_params: %w[link_id id], params: %w[required]),
    ep("delete_custom_field", :delete, "/products/:link_id/custom_fields/:id", "Delete a product custom field.", scope: "edit_products", path_params: %w[link_id id]),

    # ---- Offer codes / discounts (per product) ----
    ep("list_offer_codes", :get, "/products/:link_id/offer_codes", "List a product's discount codes.", read: true, scope: "view_sales", path_params: %w[link_id]),
    ep("get_offer_code", :get, "/products/:link_id/offer_codes/:id", "Get one discount code.", read: true, scope: "view_sales", path_params: %w[link_id id]),
    ep("create_offer_code", :post, "/products/:link_id/offer_codes", "Create a discount code on a product.", scope: "edit_products",
                                                                                                             path_params: %w[link_id], params: %w[name amount_off offer_type max_purchase_count universal amount_cents minimum_amount_cents]),
    ep("update_offer_code", :put, "/products/:link_id/offer_codes/:id", "Update a discount code (max purchase count).", scope: "edit_products",
                                                                                                                        path_params: %w[link_id id], params: %w[max_purchase_count minimum_amount_cents]),
    ep("delete_offer_code", :delete, "/products/:link_id/offer_codes/:id", "Delete a discount code.", scope: "edit_products", path_params: %w[link_id id]),

    # ---- Variant categories & variants (per product) ----
    ep("list_variant_categories", :get, "/products/:link_id/variant_categories", "List a product's variant categories.", read: true, scope: "view_sales", path_params: %w[link_id]),
    ep("get_variant_category", :get, "/products/:link_id/variant_categories/:id", "Get one variant category.", read: true, scope: "view_sales", path_params: %w[link_id id]),
    ep("create_variant_category", :post, "/products/:link_id/variant_categories", "Create a variant category.", scope: "edit_products", path_params: %w[link_id], params: %w[title]),
    ep("update_variant_category", :put, "/products/:link_id/variant_categories/:id", "Update a variant category.", scope: "edit_products", path_params: %w[link_id id], params: %w[title]),
    ep("delete_variant_category", :delete, "/products/:link_id/variant_categories/:id", "Delete a variant category.", scope: "edit_products", path_params: %w[link_id id]),
    ep("list_variants", :get, "/products/:link_id/variant_categories/:variant_category_id/variants", "List variants in a category.", read: true, scope: "view_sales", path_params: %w[link_id variant_category_id]),
    ep("get_variant", :get, "/products/:link_id/variant_categories/:variant_category_id/variants/:id", "Get one variant.", read: true, scope: "view_sales", path_params: %w[link_id variant_category_id id]),
    ep("create_variant", :post, "/products/:link_id/variant_categories/:variant_category_id/variants", "Create a variant.", scope: "edit_products",
                                                                                                                            path_params: %w[link_id variant_category_id], params: %w[name price_difference_cents max_purchase_count]),
    ep("update_variant", :put, "/products/:link_id/variant_categories/:variant_category_id/variants/:id", "Update a variant.", scope: "edit_products",
                                                                                                                               path_params: %w[link_id variant_category_id id], params: %w[name price_difference_cents max_purchase_count]),
    ep("delete_variant", :delete, "/products/:link_id/variant_categories/:variant_category_id/variants/:id", "Delete a variant.", scope: "edit_products", path_params: %w[link_id variant_category_id id]),
    ep("list_skus", :get, "/products/:link_id/skus", "List a product's SKUs.", read: true, scope: "view_sales", path_params: %w[link_id]),

    # ---- Bundle contents, thumbnail, covers ----
    ep("update_bundle_contents", :put, "/products/:link_id/bundle_contents", "Set the products contained in a bundle.", scope: "edit_products", path_params: %w[link_id], params: %w[products]),
    ep("create_thumbnail", :post, "/products/:link_id/thumbnail", "Set a product's thumbnail image.", scope: "edit_products", path_params: %w[link_id], params: %w[url signed_blob_id]),
    ep("delete_thumbnail", :delete, "/products/:link_id/thumbnail", "Remove a product's thumbnail.", scope: "edit_products", path_params: %w[link_id]),
    ep("create_cover", :post, "/products/:link_id/covers", "Add a cover image to a product.", scope: "edit_products", path_params: %w[link_id], params: %w[url signed_blob_id]),
    ep("delete_cover", :delete, "/products/:link_id/covers/:id", "Remove a product cover image.", scope: "edit_products", path_params: %w[link_id id]),

    # ---- Product subscribers ----
    ep("list_product_subscribers", :get, "/products/:link_id/subscribers", "List subscribers of a membership product. When the response includes next_page_key, pass it back as page_key to fetch the next page.", read: true, scope: "view_sales", path_params: %w[link_id], params: %w[page_key]),
    ep("get_subscriber", :get, "/subscribers/:id", "Get one subscriber by id.", read: true, scope: "view_sales", path_params: %w[id]),

    # ---- Upsells ----
    ep("list_upsells", :get, "/upsells", "List the creator's upsells.", read: true, scope: "view_sales"),
    ep("get_upsell", :get, "/upsells/:id", "Get one upsell.", read: true, scope: "view_sales", path_params: %w[id]),
    ep("create_upsell", :post, "/upsells", "Create an upsell offer.", scope: "edit_products", params: %w[name product_id variant_id offer_code cross_sell]),
    ep("update_upsell", :put, "/upsells/:id", "Update an upsell offer.", scope: "edit_products", path_params: %w[id], params: %w[name offer_code]),
    ep("delete_upsell", :delete, "/upsells/:id", "Delete an upsell offer.", scope: "edit_products", path_params: %w[id]),

    # ---- Emails (workflows / posts) ----
    # The v2 EmailsController gates EVERY action (incl. index/show) on edit_emails, so the reads use
    # edit_emails too (not view_sales) to match the real contract.
    ep("list_emails", :get, "/emails", "List the creator's email posts. Returns 10 per page; when the response includes next_page_key, pass it back as page_key to fetch the next page.", read: true, scope: "edit_emails", params: %w[page_key]),
    ep("get_email", :get, "/emails/:id", "Get one email post.", read: true, scope: "edit_emails", path_params: %w[id]),
    ep("create_email", :post, "/emails", "Draft a new email post to subscribers/customers.", scope: "edit_emails", params: %w[subject body audience product_id link_id publish draft]),
    ep("preview_email", :post, "/emails/:id/preview", "Send a preview of an email to the creator.", scope: "edit_emails", path_params: %w[id]),
    ep("send_email", :post, "/emails/:id/send", "Send an email post to its audience.", scope: "edit_emails", path_params: %w[id]),
    ep("delete_email", :delete, "/emails/:id", "Delete an email post.", scope: "edit_emails", path_params: %w[id]),

    # ---- Sales ----
    ep("sales_summary", :get, "/sales/summary", "Get an aggregate sales summary.", read: true, scope: "view_sales"),
    ep("list_sales", :get, "/sales", "List the creator's sales, optionally filtered by date/product/email.", read: true, scope: "view_sales",
                                                                                                             params: %w[after before email order_id product_id page_key]),
    ep("get_sale", :get, "/sales/:id", "Get one sale by id.", read: true, scope: "view_sales", path_params: %w[id]),
    ep("export_sales", :post, "/sales/exports", "Start a CSV export of sales (dates as YYYY-MM-DD).", scope: "view_sales", params: %w[from to product_id]),
    ep("mark_sale_as_shipped", :put, "/sales/:id/mark_as_shipped", "Mark a sale as shipped (optionally with tracking).", scope: "mark_sales_as_shipped",
                                                                                                                         path_params: %w[id], params: %w[tracking_url]),
    ep("refund_sale", :put, "/sales/:id/refund", "Refund a sale, fully or partially.", scope: "refund_sales", path_params: %w[id], params: %w[amount_cents]),
    ep("resend_receipt", :post, "/sales/:id/resend_receipt", "Resend the purchase receipt email to the buyer.", scope: "edit_sales", path_params: %w[id]),

    # ---- Payouts ----
    ep("list_payouts", :get, "/payouts", "List the creator's payouts. Returns 10 per page; when the response includes next_page_key, pass it back as page_key to fetch the next page.", read: true, scope: "view_payouts", params: %w[page_key]),
    ep("upcoming_payout", :get, "/payouts/upcoming", "Get the creator's upcoming (not-yet-paid) payout.", read: true, scope: "view_payouts"),
    ep("get_payout", :get, "/payouts/:id", "Get one payout by id.", read: true, scope: "view_payouts", path_params: %w[id]),

    # ---- Resource subscriptions (webhooks) ----
    # The underlying v2 endpoints only require view_sales, but creating/removing a webhook is OAuth-
    # app management, which the dashboard restricts to admins/owner. Gate them admin_only here so a
    # marketing member can't install a data-exfiltrating webhook through the agent. Listing is gated
    # too since it exposes the configured callback URLs. (Flagged for product review — see PR thread.)
    ep("list_resource_subscriptions", :get, "/resource_subscriptions", "List the creator's webhook resource subscriptions.", read: true, scope: "view_sales", admin_only: true),
    ep("create_resource_subscription", :put, "/resource_subscriptions", "Create a webhook resource subscription.", scope: "view_sales", admin_only: true, params: %w[resource_name post_url]),
    ep("delete_resource_subscription", :delete, "/resource_subscriptions/:id", "Delete a webhook resource subscription.", scope: "view_sales", admin_only: true, path_params: %w[id]),

    # ---- Tax forms & earnings ----
    ep("list_tax_forms", :get, "/tax_forms", "List the creator's available tax forms.", read: true, scope: "view_tax_data"),
    # /v2/earnings is behind the tax-center access concern: it requires view_tax_data (NOT view_sales)
    # and a tax `year` param. So it's effectively financial/tax data — only admin/owner get
    # view_tax_data via StoreAgentScopes, which is the right boundary (marketing can't see tax data).
    ep("get_earnings", :get, "/earnings", "Get the creator's earnings figures for a tax year.", read: true, scope: "view_tax_data", params: %w[year]),

    # ---- License management (creator-side) ----
    # The dashboard gates license management on Audience::PurchasePolicy#manage_license? (admin/
    # support only — NOT marketing). Support can't reach the Agent tab, so gate these admin_only so a
    # marketing member can't enable/disable/rotate customer license keys through the agent.
    ep("enable_license", :put, "/licenses/enable", "Enable a license key.", scope: "edit_products", admin_only: true, params: %w[product_id license_key]),
    ep("disable_license", :put, "/licenses/disable", "Disable a license key.", scope: "edit_products", admin_only: true, params: %w[product_id license_key]),
    ep("decrement_license_uses", :put, "/licenses/decrement_uses_count", "Decrement a license key's uses count.", scope: "edit_products", admin_only: true, params: %w[product_id license_key]),
    ep("rotate_license", :put, "/licenses/rotate", "Rotate (reissue) a license key.", scope: "edit_products", admin_only: true, params: %w[product_id license_key]),
  ].freeze

  BY_ID = ENDPOINTS.index_by(&:id).freeze

  def self.find(id) = BY_ID[id.to_s]
  def self.reads = ENDPOINTS.select(&:read?)
  def self.writes = ENDPOINTS.select(&:write?)
  def self.read_ids = reads.map(&:id)
  def self.write_ids = writes.map(&:id)

  # A compact human-readable manifest injected into the system prompt so the model knows what each
  # endpoint id does, which path params it needs, and which body/query params it accepts — without
  # bloating the tool JSON schema. Surfacing the param names is what stops the model from inventing
  # plausible-but-wrong keys (e.g. `percent_off` instead of the API's `amount_off` + `offer_type`).
  def self.manifest(kind)
    list = kind == :read ? reads : writes
    list.map do |e|
      pp = e.path_params.any? ? " (path: #{e.path_params.join(', ')})" : ""
      bp = e.params.any? ? " (params: #{e.params.join(', ')})" : ""
      "- #{e.id}#{pp}#{bp}: #{e.summary}"
    end.join("\n")
  end
end
