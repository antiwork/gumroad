# frozen_string_literal: true

class ProductDuplicatorService
  REDIS_STORAGE_NS = Redis::Namespace.new(:product_duplicator_service, redis: $redis)
  private_constant :REDIS_STORAGE_NS

  TIMEOUT_FOR_DUPLICATE_PRODUCT_CACHE = 10.minutes
  private_constant :TIMEOUT_FOR_DUPLICATE_PRODUCT_CACHE

  DUPLICATING = "product_duplicating"
  DUPLICATED = "product_duplicated"
  DUPLICATION_FAILED = "product_duplication_failed"

  attr_reader :product, :duplicated_product

  def initialize(product_id)
    @product = Link.find(product_id)

    # Maintains a mapping of original product file external IDs and
    # the new product file external IDs like:
    # { "old_product_file_external_id" => "new_product_file_external_id" }
    @product_file_external_ids_mapping = {}
  end

  def duplicate
    ApplicationRecord.connection.stick_to_primary!
    ApplicationRecord.connection.transaction do
      @duplicated_product = product.dup
      duplicated_product.unique_permalink = nil
      duplicated_product.custom_permalink = nil
      duplicated_product.name = "#{product.name} (copy)"
      duplicated_product.price_cents = product.price_cents
      duplicated_product.rental_price_cents = product.rental_price_cents if product.rental_price_cents.present?
      duplicated_product.is_collab = false
      mark_duplicate_product_as_draft
      duplicated_product.is_duplicating = false
      duplicated_product.save!

      duplicate_prices
      duplicate_asset_previews
      duplicate_thumbnail
      duplicate_product_files # Copy product files before copying the variants and skus.
      duplicate_public_product_files
      duplicate_rich_content(original_entity: product, duplicate_entity: duplicated_product)
      duplicate_offer_codes
      duplicate_product_taggings
      duplicate_skus # Copy skus before variant categories and variants
      duplicate_variant_categories_and_variants
      duplicate_preorder_link
      duplicate_third_party_analytics
      duplicate_shipping_destinations
      duplicate_refund_policy
    end

    # Post process Asset Previews if product was persisted from outside the transaction
    post_process_attachments

    set_recently_duplicated_product

    duplicated_product
  end

  def recently_duplicated_product
    duplicated_product_id = REDIS_STORAGE_NS.get(product.id)
    Link.where(id: duplicated_product_id).first
  end

  private
    attr_reader :product_file_external_ids_mapping

    def set_recently_duplicated_product
      REDIS_STORAGE_NS.setex(product.id, TIMEOUT_FOR_DUPLICATE_PRODUCT_CACHE, duplicated_product.id)
    end

    def mark_duplicate_product_as_draft
      duplicated_product.draft = true
      duplicated_product.purchase_disabled_at = Time.current
    end

    def duplicate_prices
      duplicated_product.prices.each(&:mark_deleted!) # Delete the default prices that are associated with the product on creation. Ref: Product::Prices.associate_price.
      product.prices.alive.each do |price|
        new_price = price.dup
        new_price.link = duplicated_product
        new_price.save!
      end
    end

    def duplicate_asset_previews
      product.asset_previews.alive.in_order.each do |asset_preview|
        new_asset_preview = asset_preview.dup
        new_asset_preview.link = duplicated_product
        new_asset_preview.file.attach duped_blob(asset_preview.file) if asset_preview.file.attached?
        new_asset_preview.save!
      end
    end

    def duplicate_thumbnail
      return unless product.thumbnail.present?

      new_thumbnail = product.thumbnail.dup
      new_thumbnail.product = duplicated_product
      new_thumbnail.file.attach duped_blob(product.thumbnail.file) if product.thumbnail.file.attached?
      new_thumbnail.file.analyze
      new_thumbnail.save!
    end

    def post_process_attachments
      return unless duplicated_product.present?

      duplicated_product.asset_previews.each do |asset_preview|
        asset_preview.file.analyze if asset_preview.file.attached?
      end

      return unless duplicated_product.thumbnail.present?

      duplicated_product.thumbnail.file.analyze if duplicated_product.thumbnail.file.attached?
    end

    def duped_blob(file)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(file.download), filename: file.filename, content_type: file.content_type)
      blob.analyze
      blob
    end

    def duplicate_product_files
      product_folder_ids_mapping = {}

      product.product_folders.alive.each do |product_folder|
        new_product_folder = product_folder.dup
        new_product_folder.link = duplicated_product
        new_product_folder.save!

        product_folder_ids_mapping[product_folder.id] = new_product_folder.id
      end

      product.product_files.alive.each do |product_file|
        new_product_file = product_file.dup
        new_product_file.link = duplicated_product
        new_product_file.is_linked_to_existing_file = true
        new_product_file.folder_id = product_folder_ids_mapping[product_file.folder_id]

        product_file.transcoded_videos.alive.each do |transcoded_video|
          new_transcoded_video = transcoded_video.dup
          new_transcoded_video.streamable = new_product_file
          new_transcoded_video.link = duplicated_product
          new_transcoded_video.save!
        end

        product_file.subtitle_files.each do |subtitle_file|
          new_subtitle_file = subtitle_file.dup
          new_subtitle_file.product_file = new_product_file
          new_subtitle_file.save!
        end

        if product_file.dropbox_file
          new_dropbox_file = product_file.dropbox_file.dup
          new_dropbox_file.product_file = new_product_file
          new_dropbox_file.link = duplicated_product
          new_dropbox_file.save!
        end

        new_product_file.save!

        @product_file_external_ids_mapping[product_file.external_id] = new_product_file.external_id
      end
    end

    def duplicate_public_product_files
      public_files = product.public_files.alive.with_attached_file
      description = duplicated_product.description
      doc = Nokogiri::HTML.fragment(description)

      doc.css("public-file-embed").each do |embed_node|
        id = embed_node.attr("id")
        if id.blank?
          embed_node.remove
          next
        end

        public_file = public_files.find { _1.public_id == id }
        if public_file.present?
          new_public_file = public_file.dup
          new_public_file.file.attach(public_file.file.blob)
          new_public_file.resource = duplicated_product
          new_public_file.public_id = PublicFile.generate_public_id
          new_public_file.save!

          embed_node.set_attribute("id", new_public_file.public_id)
        else
          embed_node.remove
        end
      end

      duplicated_product.update!(description: doc.to_html)
    end

    def duplicate_offer_codes
      duplicated_product.offer_codes = product.offer_codes
    end

    def duplicate_product_taggings
      product.product_taggings.each do |product_tagging|
        new_product_tagging = product_tagging.dup
        new_product_tagging.product = duplicated_product
        new_product_tagging.save!
      end
    end

    def duplicate_variant_categories_and_variants
      if product.is_tiered_membership
        tier_category = duplicated_product.variant_categories.alive.first
        if tier_category
          tier_category.mark_deleted!
        end
      end

      product.variant_categories.each do |variant_category|
        new_variant_category = variant_category.dup
        new_variant_category.link = duplicated_product
        new_variant_category.save!
        variant_category.variants.each do |variant|
          new_variant = variant.dup
          new_variant.variant_category = new_variant_category
          duplicate_variant_product_files(original_variant: variant, duplicate_variant: new_variant)
          variant.skus.each do |sku|
            new_sku = duplicated_product.skus.where(name: sku.name).first
            new_variant.skus << new_sku
          end
          new_variant.save!

          duplicate_rich_content(original_entity: variant, duplicate_entity: new_variant)
        end
      end
    end

    def duplicate_skus
      product.skus.each do |sku|
        new_sku = sku.dup
        new_sku.link = duplicated_product
        duplicate_variant_product_files(original_variant: sku, duplicate_variant: new_sku)
        new_sku.save!
      end
    end

    def duplicate_variant_product_files(original_variant:, duplicate_variant:)
      original_variant.product_files.alive.each do |product_file|
        duplicate_product_file_external_id = product_file_external_ids_mapping[product_file.external_id]
        next if duplicate_product_file_external_id.blank?

        duplicate_product_file = ProductFile.find_by_external_id(duplicate_product_file_external_id)
        next if duplicate_product_file.blank?

        duplicate_variant.product_files << duplicate_product_file
      end
    end

    def duplicate_preorder_link
      return unless product.preorder_link

      new_preorder_link = product.preorder_link.dup
      new_preorder_link.link = duplicated_product
      new_preorder_link.release_at = 1.month.from_now if new_preorder_link.release_at <= 24.hours.from_now
      new_preorder_link.save!
    end

    def duplicate_third_party_analytics
      product.third_party_analytics.each do |third_party_analytic|
        new_third_party_analytic = third_party_analytic.dup
        new_third_party_analytic.link = duplicated_product
        new_third_party_analytic.save!
      end
    end

    def duplicate_shipping_destinations
      product.shipping_destinations.each do |shipping_destination|
        new_shipping_destination = shipping_destination.dup
        new_shipping_destination.link = duplicated_product
        new_shipping_destination.save!
      end
    end

    def duplicate_refund_policy
      return unless product.product_refund_policy.present?

      new_refund_policy = product.product_refund_policy.dup
      new_refund_policy.product = duplicated_product
      new_refund_policy.save!
    end

    def duplicate_rich_content(original_entity:, duplicate_entity:)
      original_entity.alive_rich_contents.find_each do |original_entity_rich_content|
        duplicate_entity_rich_content = original_entity_rich_content.dup
        duplicate_entity_rich_content.entity = duplicate_entity
        update_file_embed_ids_in_rich_content(duplicate_entity_rich_content.description)
        duplicate_entity_rich_content.save!
      end
    end

    def update_file_embed_ids_in_rich_content(content)
      content.each do |node|
        update_file_embed_ids_in_rich_content(node["content"]) if node["type"] == RichContent::FILE_EMBED_GROUP_NODE_TYPE

        next if node["type"] != "fileEmbed"
        next if node.dig("attrs", "id").blank?

        new_product_file_external_id = product_file_external_ids_mapping[node.dig("attrs", "id")]
        next if new_product_file_external_id.blank?

        node["attrs"]["id"] = new_product_file_external_id
      end
    end
end
