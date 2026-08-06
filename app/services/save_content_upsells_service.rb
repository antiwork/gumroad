# frozen_string_literal: true

class SaveContentUpsellsService
  MAX_FIXED_DISCOUNT_CENTS = (2**31) - 1

  def initialize(seller:, content:, old_content:)
    @seller = seller
    @content = content
    @old_content = old_content
  end

  def from_html
    old_doc = Nokogiri::HTML.fragment(old_content)
    new_doc = Nokogiri::HTML.fragment(content)

    old_upsell_ids = old_doc.css("upsell-card").map { |card| card["id"] }.compact
    new_upsell_cards = new_doc.css("upsell-card")
    new_upsell_ids = new_upsell_cards.map { |card| card["id"] }.compact
    remaining_old_upsell_ids = old_upsell_ids.tally

    delete_removed_upsells!(old_upsell_ids - new_upsell_ids)

    new_upsell_cards.each do |card|
      next if consume_old_upsell_id?(card["id"], remaining_old_upsell_ids)

      card.remove_attribute("id")
      product_id = ObfuscateIds.decrypt(card["productid"])
      variant_id = ObfuscateIds.decrypt(card["variantid"]) if card["variantid"]
      discount = parse_discount(card["discount"]) if card["discount"]
      card["id"] = create_upsell!(product_id, variant_id, discount).external_id
    end

    new_doc.to_html
  end

  def from_rich_content
    old_upsell_ids = collect_upsell_nodes(old_content).filter_map { |node| node.dig("attrs", "id") }
    new_upsell_nodes = collect_upsell_nodes(content)
    new_upsell_ids = new_upsell_nodes.map { |node| node.dig("attrs", "id") }.compact
    remaining_old_upsell_ids = old_upsell_ids.tally

    delete_removed_upsells!(old_upsell_ids - new_upsell_ids)

    new_upsell_nodes.each do |node|
      next if consume_old_upsell_id?(node.dig("attrs", "id"), remaining_old_upsell_ids)

      node["attrs"].delete("id")
      product_id = ObfuscateIds.decrypt(node.dig("attrs", "productId"))
      variant_id = ObfuscateIds.decrypt(node.dig("attrs", "variantId")) if node.dig("attrs", "variantId")
      discount = node.dig("attrs", "discount")
      node["attrs"]["id"] = create_upsell!(product_id, variant_id, discount).external_id
    end

    content
  end

  private
    attr_reader :seller, :content, :old_content, :error

    def consume_old_upsell_id?(upsell_id, remaining_old_upsell_ids)
      return false if remaining_old_upsell_ids.fetch(upsell_id, 0).zero?

      remaining_old_upsell_ids[upsell_id] -= 1
      true
    end

    # Rich-content nodes nest arbitrarily (e.g. an upsellCard inside a blockquote), so a
    # top-level-only scan misses those cards and never mints or retires their Upsell rows.
    # Nodes arrive as plain Hashes from specs/services but as ActionController::Parameters
    # from controller request params (e.g. links_controller, SellerProfileSections::SaveService) —
    # Parameters is not a Hash subclass, so both must be accepted or the scan silently sees nothing.
    def collect_upsell_nodes(nodes)
      Array(nodes).flat_map do |node|
        next [] unless node.is_a?(Hash) || node.is_a?(ActionController::Parameters)
        nested = collect_upsell_nodes(node["content"])
        node["type"] == "upsellCard" ? [node, *nested] : nested
      end
    end

    def delete_removed_upsells!(upsell_ids)
      upsell_ids.each do |upsell_id|
        upsell = seller.upsells.find_by_external_id(upsell_id)
        if upsell
          upsell.offer_code&.mark_deleted!
          upsell.mark_deleted!
        end
      end
    end

    def create_upsell!(product_id, variant_id, discount)
      product = Link.find_by(id: product_id)
      raise_invalid_upsell!(:product) if product.nil?

      variant = BaseVariant.find_by(id: variant_id) if variant_id
      raise_invalid_upsell!(:variant) if variant_id && variant.nil?

      Upsell.create!(
        seller:,
        product:,
        variant:,
        is_content_upsell: true,
        cross_sell: true,
        offer_code: build_offer_code(product_id, discount),
      )
    end

    def build_offer_code(product_id, discount)
      return nil unless discount.present?

      discount = parse_discount(discount)

      OfferCode.build(
        user: seller,
        code: nil,
        amount_cents: discount["type"] == "fixed" ? discount["cents"] : nil,
        amount_percentage: discount["type"] == "percent" ? discount["percents"] : nil,
        universal: false,
        product_ids: [product_id]
      )
    end

    def parse_discount(discount)
      discount = JSON.parse(discount) if discount.is_a?(String)
      unless discount.is_a?(Hash) || discount.is_a?(ActionController::Parameters)
        raise_invalid_upsell!(:base, "Content contains invalid upsell data.")
      end

      amount = discount[discount["type"] == "fixed" ? "cents" : "percents"]
      valid = case discount["type"]
              when "fixed" then amount.is_a?(Integer) && amount.between?(0, MAX_FIXED_DISCOUNT_CENTS)
              when "percent" then amount.is_a?(Integer) && amount.between?(0, 100)
              else false
      end
      raise_invalid_upsell!(:base, "Content contains invalid upsell data.") unless valid

      discount
    rescue JSON::ParserError
      raise_invalid_upsell!(:base, "Content contains invalid upsell data.")
    end

    def raise_invalid_upsell!(attribute, message = "is invalid")
      upsell = Upsell.new
      upsell.errors.add(attribute, message)
      raise ActiveRecord::RecordInvalid, upsell
    end
end
