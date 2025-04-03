# frozen_string_literal: true

class Product::SavePostPurchaseCustomFieldsService
  NODE_TYPE_TO_FIELD_TYPE_MAPPING = CustomField::FIELD_TYPE_TO_NODE_TYPE_MAPPING.invert

  def initialize(product)
    @product = product
  end

  def perform
    if @product.alive_variants.exists? && @product.not_has_same_rich_content_for_all_variants?
      update_for_rich_contents(@product.alive_variants.map { _1.rich_contents.alive }.flatten)
    else
      update_for_rich_contents(@product.rich_contents.alive)
    end
  end

  private
    def update_for_rich_contents(rich_contents)
      existing = @product.custom_fields.is_post_purchase
      to_keep = []

      rich_contents.each do |rich_content|
        rich_content.custom_field_nodes.each do |node|
          node["attrs"] ||= {}
          field = (existing.find { _1.external_id == node["attrs"]["id"] }) || @product.custom_fields.build
          field.update!(
            seller: @product.user,
            products: [@product],
            name: node["attrs"]["label"],
            field_type: NODE_TYPE_TO_FIELD_TYPE_MAPPING[node["type"]],
            is_post_purchase: true
          )
          node["attrs"]["id"] = field.external_id
          to_keep << field
        end
        rich_content.save!
      end
      (existing - to_keep).each(&:destroy!)
    end
end
