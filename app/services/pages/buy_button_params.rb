# frozen_string_literal: true

# Reads buyer-selection attributes off a `[data-gumroad-action="buy"]` element
# and returns the subset that's valid for *this* product. Lenient by design: any
# invalid value (variant the product doesn't have, recurrence it doesn't offer,
# PWYW price under the minimum, etc.) is silently dropped so a typo in an
# agent-authored landing page falls back to the product's default checkout
# instead of breaking the buyer's view.
#
# Supported attributes (all optional):
#   data-gumroad-option     → variant name; matched against `product.options[].name`
#   data-gumroad-quantity   → integer ≥ 1; gated by `quantity_enabled`; bounded by `max_purchase_count`
#   data-gumroad-price      → decimal in major units (e.g. "9.99"); gated by `customizable_price`; must be ≥ the product's min price
#   data-gumroad-recurrence → recurrence key (e.g. "monthly"); gated by `is_recurring_billing`; must be in `product.recurrences[:enabled]`
#
# Returned hash uses the same keys the checkout already accepts on the URL
# (`?variant=&quantity=&price=&recurrence=` — see LinksController#show), so the
# caller can pass it straight through to the wrapper without remapping.
#
# Build the validator once per render (`new(product)`) and call `validate(node)`
# per buy element — the product-derived lookups (variant names, allowed
# recurrences) are memoized on the instance so a page with many buy buttons
# doesn't re-query `product.options` / `product.recurrences` per button.
class Pages::BuyButtonParams
  # One-shot helper for callers validating a single node. The interpolator
  # instantiates the validator once and reuses it across all buy buttons.
  def self.from(node, product:)
    new(product).validate(node)
  end

  def initialize(product)
    @product = product
  end

  def validate(node)
    {}.tap do |params|
      if (v = variant(node)); params[:variant] = v; end
      if (q = quantity(node)); params[:quantity] = q; end
      if (p = price(node)); params[:price] = p; end
      if (r = recurrence(node)); params[:recurrence] = r; end
    end
  end

  private
    attr_reader :product

    def variant(node)
      raw = node["data-gumroad-option"]
      return nil if raw.blank?

      option_names.include?(raw.to_s) ? raw.to_s : nil
    end

    def quantity(node)
      return nil unless product.quantity_enabled

      raw = node["data-gumroad-quantity"]
      return nil if raw.blank?

      n = Integer(raw, 10, exception: false)
      return nil unless n && n >= 1

      max = product.max_purchase_count
      return nil if max && n > max

      n
    end

    def price(node)
      return nil unless product.customizable_price

      raw = node["data-gumroad-price"]
      return nil if raw.blank?

      val = Float(raw, exception: false)
      return nil unless val && val.finite? && val > 0

      # Convert to cents the same way the checkout does — LinksController#show
      # uses (price.to_f * 100).to_i — so this validation never admits a price the
      # checkout would itself truncate below the minimum and refuse to honor. The
      # float quirk (e.g. 9.99 → 998) lives on both sides; dropping such a
      # boundary price here just falls the buy button back to the default checkout.
      val_cents = (val * 100).to_i
      return nil if val_cents < product.price_cents.to_i

      val
    end

    def recurrence(node)
      return nil unless product.is_recurring_billing

      raw = node["data-gumroad-recurrence"]
      return nil if raw.blank?

      enabled_recurrences.include?(raw.to_s) ? raw.to_s : nil
    end

    def option_names
      @option_names ||= product.options.map { |o| o[:name].to_s }.to_set
    end

    def enabled_recurrences
      @enabled_recurrences ||= (product.recurrences[:enabled] || []).map { |r| r[:recurrence].to_s }.to_set
    end
end
