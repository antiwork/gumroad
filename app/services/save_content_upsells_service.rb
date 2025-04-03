# frozen_string_literal: true

class SaveContentUpsellsService
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

    delete_removed_upsells!(old_upsell_ids - new_upsell_ids)

    new_upsell_cards.each do |card|
      next if card["id"].present?

      product_id = ObfuscateIds.decrypt(card["productid"])
      discount = JSON.parse(card["discount"]) if card["discount"]
      card["id"] = create_upsell!(product_id, discount).external_id
    end

    new_doc.to_html
  end

  def from_rich_content
    old_upsell_ids = old_content&.filter_map { |node| node["type"] == "upsellCard" ? node.dig("attrs", "id") : nil } || []
    new_upsell_nodes = content&.select { |node| node["type"] == "upsellCard" } || []
    new_upsell_ids = new_upsell_nodes.map { |node| node.dig("attrs", "id") }.compact

    delete_removed_upsells!(old_upsell_ids - new_upsell_ids)

    new_upsell_nodes.each do |node|
      next if node.dig("attrs", "id").present?

      product_id = ObfuscateIds.decrypt(node.dig("attrs", "productId"))
      discount = node.dig("attrs", "discount")
      node["attrs"]["id"] = create_upsell!(product_id, discount).external_id
    end

    content
  end

  private
    attr_reader :seller, :content, :old_content, :error

    def delete_removed_upsells!(upsell_ids)
      upsell_ids.each do |upsell_id|
        upsell = seller.upsells.find_by_external_id(upsell_id)
        if upsell
          upsell.offer_code&.mark_deleted!
          upsell.mark_deleted!
        end
      end
    end

    def create_upsell!(product_id, discount)
      Upsell.create!(
        seller:,
        product_id:,
        is_content_upsell: true,
        cross_sell: true,
        offer_code: build_offer_code(product_id, discount),
      )
    end

    def build_offer_code(product_id, discount)
      return nil unless discount.present?

      discount = JSON.parse(discount) if discount.is_a?(String)

      OfferCode.build(
        user: seller,
        code: nil,
        amount_cents: discount["type"] == "fixed" ? discount["cents"] : nil,
        amount_percentage: discount["type"] == "percent" ? discount["percents"] : nil,
        universal: false,
        product_ids: [product_id]
      )
    end
end
