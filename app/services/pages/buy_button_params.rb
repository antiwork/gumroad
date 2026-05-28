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
class Pages::BuyButtonParams
  def self.from(node, product:)
    new(node, product).build
  end

  def initialize(node, product)
    @node = node
    @product = product
  end

  def build
    {}.tap do |params|
      params[:variant] = variant if variant
      params[:quantity] = quantity if quantity
      params[:price] = price if price
      params[:recurrence] = recurrence if recurrence
    end
  end

  private
    attr_reader :node, :product

    def variant
      raw = node["data-gumroad-option"]
      return nil if raw.blank?

      options = product.options
      return nil if options.empty?

      options.find { |o| o[:name].to_s == raw.to_s } ? raw.to_s : nil
    end

    def quantity
      return nil unless product.quantity_enabled

      raw = node["data-gumroad-quantity"]
      return nil if raw.blank?

      n = Integer(raw, 10) rescue nil
      return nil unless n && n >= 1

      max = product.max_purchase_count
      return nil if max && n > max

      n
    end

    def price
      return nil unless product.customizable_price

      raw = node["data-gumroad-price"]
      return nil if raw.blank?

      val = Float(raw) rescue nil
      return nil unless val && val.finite? && val > 0

      # Mirror the checkout's expectation: ?price arrives in major units and the
      # show action multiplies by 100 to get cents (see LinksController#show).
      val_cents = (val * 100).to_i
      return nil if val_cents < product.price_cents.to_i

      val
    end

    def recurrence
      return nil unless product.is_recurring_billing

      raw = node["data-gumroad-recurrence"]
      return nil if raw.blank?

      enabled = product.recurrences&.dig(:enabled) || []
      enabled.find { |r| r[:recurrence].to_s == raw.to_s } ? raw.to_s : nil
    end
end
