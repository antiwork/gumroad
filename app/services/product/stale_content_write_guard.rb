# frozen_string_literal: true

# Rejects a product-editor save that was built from a stale snapshot before it
# can overwrite newer data. The editor submits the FULL product on every save,
# so a session working from outdated data (an old tab, a slow load, a second
# editor session) resubmits existing page/variant ids carrying old content.
# Those writes are plain in-place updates: nothing is deleted, so the deletion
# guards (Product::RichContentDeletionGuard, shipped for gumroad-private#1230)
# never fire, and the newer content is silently reverted with no confirmation
# and no notification. This guard is the optimistic-concurrency counterpart
# for that overwrite case (gumroad-private#1295).
#
# How it works: the editor is served each page's and variant's `updated_at`
# when it loads (and refreshed values after every successful save), and echoes
# them back with the save payload. For a membership tier the served value also
# covers its prices, which live in a separate table and don't bump the tier
# row itself (see snapshot_at). Inside the save's transaction, after the
# product row is locked and before anything is mutated, this guard compares
# each echoed timestamp against the stored row. Running under that lock is
# what makes the check binding rather than advisory: concurrent saves of the
# same product are serialized on the row, so the second one re-reads what the
# first wrote instead of both reading the same pre-write state and both being
# allowed through. A stored row
# that changed AFTER the snapshot was served means another session (or another
# tab) saved in between — the save is rejected with a structured conflict so
# the editor can tell the seller to reload, and a Sentry notification is sent
# alongside the rejection (diagnostics, not a substitute for it).
#
# The check is deliberately fail-open when a timestamp is missing or
# unparseable: payloads from editor sessions predating this feature (open tabs
# at deploy time) and any client that doesn't echo timestamps keep saving the
# way they always did. Only a client that claims a snapshot time is held to it.
class Product::StaleContentWriteGuard
  MESSAGE = "This product was updated after this page was loaded, so saving now would overwrite those newer changes. Please reload the page to get the latest content, then make your edits again."

  # Raised before any mutation when the payload echoes snapshot timestamps
  # older than the stored rows. Carries the conflicting records so the
  # controller can return them and the editor can show the seller exactly
  # what changed underneath the session.
  class StaleContentConflict < Link::LinkInvalid
    attr_reader :stale_records

    def initialize(message, stale_records:)
      @stale_records = stale_records
      super(message)
    end
  end

  # pages_params: every page in the save payload (product-level and
  # variant-level), each a hash with :id and the echoed :updated_at.
  # variants_params: the payload's variants, each with :id and the echoed
  # :updated_at.
  # diagnostics: the same non-PII pre-save counts/flags the deletion guards
  # attach to their notifications (LinksController#deletion_guard_diagnostics).
  def self.ensure_fresh!(product:, pages_params:, variants_params:, diagnostics: {})
    stale_records = stale_pages(product, pages_params) + stale_variants(product, variants_params)
    return if stale_records.empty?

    # The notification accompanies the rejection so incidents are visible and
    # diagnosable from the alert alone — it never replaces the rejection.
    ErrorNotifier.notify(
      "Blocked product save built from a stale snapshot (would overwrite newer content)",
      product_id: product.id,
      stale_page_external_ids: stale_records.select { _1[:type] == "page" }.map { _1[:id] },
      stale_variant_external_ids: stale_records.select { _1[:type] == "variant" }.map { _1[:id] },
      **diagnostics
    )
    product.errors.add(:base, MESSAGE)
    raise StaleContentConflict.new(MESSAGE, stale_records:)
  end

  def self.stale_pages(product, pages_params)
    stored_pages_by_external_id = (product.alive_rich_contents.to_a +
      product.current_base_variants.flat_map { _1.alive_rich_contents.to_a }).index_by(&:external_id)

    Array.wrap(pages_params).filter_map do |page|
      stored = page[:id].present? ? stored_pages_by_external_id[page[:id]] : nil
      next unless stale?(stored, page[:updated_at])

      { type: "page", id: stored.external_id, name: stored.title }
    end
  end
  private_class_method :stale_pages

  def self.stale_variants(product, variants_params)
    stored_variants_by_external_id = product.current_base_variants.index_by(&:external_id)

    Array.wrap(variants_params).filter_map do |variant|
      stored = variant[:id].present? ? stored_variants_by_external_id[variant[:id]] : nil
      next unless stale?(stored, variant[:updated_at], changed_at: stored && snapshot_at(stored))
      next unless overwrites_variant_attributes?(stored, variant) || overwrites_variant_prices?(stored, variant)

      { type: "variant", id: stored.external_id, name: stored.name }
    end
  end
  private_class_method :stale_variants

  # When a variant last changed in a way the editor can overwrite. A membership
  # tier's prices are rows in a separate table (VariantPrice), and saving them
  # does NOT bump the tier row's own updated_at — so the tier row's timestamp
  # alone would let a stale save revert a price another session had just
  # changed. Take the newest of the variant row and its alive price rows so a
  # price-only change is visible to the freshness check.
  #
  # This is also the value served to the editor as the variant's snapshot
  # timestamp (ProductPresenter) and refreshed after every save
  # (LinksController#content_updated_at_response). Those three have to agree:
  # if the editor were served the bare variant timestamp while the check
  # compared against the newer price timestamp, a seller whose tier prices were
  # last touched after the tier row itself would be told their own price edit
  # conflicts.
  def self.snapshot_at(variant)
    price_timestamps = variant.respond_to?(:alive_prices) ? variant.alive_prices.map(&:updated_at) : []
    [variant.updated_at, *price_timestamps].compact.max
  end

  # Variant attributes the editor lets a seller change that live on the variant
  # row itself, so a stale save would revert them. Membership prices live in a
  # separate table and are compared separately (overwrites_variant_prices?).
  COMPARED_VARIANT_ATTRIBUTES = %i[name description price_difference_cents max_purchase_count duration_in_minutes].freeze

  # Whether a stale variant snapshot would actually change anything the seller
  # edits. A newer updated_at on a variant row does NOT by itself mean another
  # editor session saved: every sale of a limited-quantity variant touches the
  # row to bust the product cache (Purchase#touch_variants_if_limited_quantity,
  # via the after_transition on successful purchases). Rejecting on the
  # timestamp alone would block a seller from saving simply because their
  # product sold after they opened the editor — the exact opposite of the
  # protection this guard exists to give them.
  #
  # So a variant only counts as a conflict when the payload's values differ
  # from what's stored: that's when writing them would revert someone else's
  # change. When they're identical the write is a no-op for this variant and
  # there is nothing to protect. Attributes the payload doesn't mention are
  # skipped (the save won't touch them). Compared as strings because the
  # payload arrives as JSON/form values while the stored values are typed.
  def self.overwrites_variant_attributes?(stored, submitted)
    COMPARED_VARIANT_ATTRIBUTES.any? do |attribute|
      next false unless submitted.key?(attribute) || submitted.key?(attribute.to_s)

      submitted_value = submitted[attribute].nil? ? submitted[attribute.to_s] : submitted[attribute]
      submitted_value.to_s != stored.public_send(attribute).to_s
    end
  end
  private_class_method :overwrites_variant_attributes?

  # Whether the payload's membership prices for this tier differ from what's
  # stored — the same "would this write revert someone else's change?" question
  # as overwrites_variant_attributes?, asked of the tier's prices.
  #
  # Membership tier prices are VariantPrice rows, not columns on the variant, so
  # a full editor save that carries stale recurrence_price_values reverts them
  # without touching any attribute compared above. The editor submits cents
  # (`price_cents` / `suggested_price_cents`); the older form fields (`price` /
  # `suggested_price`, formatted strings) are only compared when no cents value
  # was submitted, so formatting differences can't manufacture a conflict.
  def self.overwrites_variant_prices?(stored, submitted)
    submitted_prices = fetch_value(submitted, :recurrence_price_values)
    return false if submitted_prices.blank?
    return false unless stored.respond_to?(:recurrence_price_values)

    stored_prices = stored.recurrence_price_values(for_edit: true)
    # ActionController::Parameters isn't Enumerable, so iterate its pairs
    # explicitly rather than relying on Enumerable#any?.
    submitted_prices.each_pair.any? do |recurrence, attributes|
      stored_attributes = stored_prices[recurrence.to_s] || {}
      submitted_enabled = fetch_value(attributes, :enabled).to_s == "true"
      # A recurrence being switched on or off is itself a change.
      next true if submitted_enabled != (stored_attributes[:enabled] == true)
      # Prices of a disabled recurrence aren't written, so nothing to protect.
      next false unless submitted_enabled

      price_differs?(attributes, stored_attributes, :price_cents, :price) ||
        price_differs?(attributes, stored_attributes, :suggested_price_cents, :suggested_price)
    end
  end
  private_class_method :overwrites_variant_prices?

  def self.price_differs?(submitted_attributes, stored_attributes, cents_key, formatted_key)
    submitted_cents = fetch_value(submitted_attributes, cents_key)
    return submitted_cents.to_s != stored_attributes[cents_key].to_s if submitted_cents.present?

    submitted_formatted = fetch_value(submitted_attributes, formatted_key)
    return false if submitted_formatted.blank?

    submitted_formatted.to_s != stored_attributes[formatted_key].to_s
  end
  private_class_method :price_differs?

  # Reads a value from a payload hash that may use symbol or string keys
  # (ActionController::Parameters and plain hashes both reach this guard).
  def self.fetch_value(attributes, key)
    return nil if attributes.nil?

    attributes[key].nil? ? attributes[key.to_s] : attributes[key]
  end
  private_class_method :fetch_value

  # Stale = the stored record changed after the snapshot the client echoed.
  # `changed_at` defaults to the row's own updated_at; callers pass a different
  # value where a record's editable state also lives in other rows (a
  # membership tier's prices — see snapshot_at).
  # Compared at whole-second precision because that's what the row's JSON
  # serialization served to the editor (this app's JSON time_precision is 0;
  # the column stores microseconds). Two writes inside the same second can't
  # be told apart — acceptable, since the incident class this guards against
  # involves minutes-to-days-old snapshots. Unknown ids are new records, not
  # overwrites; missing or unparseable echoes fail open (see the class
  # comment).
  def self.stale?(stored, echoed_updated_at, changed_at: nil)
    return false if stored.nil? || echoed_updated_at.blank?

    echoed = begin
      Time.zone.parse(echoed_updated_at.to_s)
    rescue ArgumentError
      nil
    end
    return false if echoed.nil?

    (changed_at || stored.updated_at).to_i > echoed.to_i
  end
  private_class_method :stale?
end
