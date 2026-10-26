# frozen_string_literal: true

# Creates one draft product from a normalized partner product (see PartnerMigration.normalize_products),
# in three steps that PartnerMigrationImportJob runs in order:
#
# 1. download_files: before the product exists, so a network error leaves no partial product.
# 2. create_product!: in one transaction, which the job also uses to record the product.
# 3. attach_media: covers and the thumbnail are optional, so a failure is a warning, not an error.
class PartnerMigration::ProductImporter
  MEDIA_ERRORS = [
    PartnerMigration::RemoteFileTransfer::Error, PartnerMigration::RemoteFileTransfer::TemporaryError,
    URI::InvalidURIError, Addressable::URI::InvalidURIError, ActiveRecord::RecordInvalid, ActiveStorage::FileNotFoundError,
    SsrfFilter::Error, Thumbnail::RemoteFileTooLarge, Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError,
    *INTERNET_EXCEPTIONS
  ].freeze

  def initialize(seller:, attributes:)
    @seller = seller
    @attributes = attributes
  end

  # Returns the S3 URLs of the product files, in order. On an error, deletes the files it uploaded.
  def download_files
    @uploaded_urls = []
    attributes["files"].each { @uploaded_urls << PartnerMigration::RemoteFileTransfer.new(seller:, url: _1["url"]).perform }
    @uploaded_urls
  rescue StandardError
    discard_uploaded_files
    raise
  end

  # Deletes the uploaded files when the product that would keep them is not created. No database
  # record points to them, so RemoveDeletedFilesFromS3Job cannot find them later.
  def discard_uploaded_files
    keys = @uploaded_urls.to_a.map { _1.delete_prefix(S3_BASE_URL) }
    return if keys.empty?

    Aws::S3::Resource.new.bucket(S3_BUCKET).delete_objects(delete: { objects: keys.map { { key: _1 } } })
  rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError => e
    ErrorNotifier.notify(e, partner_migration_s3_keys: keys)
  end

  def create_product!(file_urls)
    product = seller.links.build(
      name: attributes["name"],
      description: attributes["description"],
      price_cents: attributes["price"],
      price_currency_type: attributes["price_currency_type"],
      native_type: Link::NATIVE_TYPE_DIGITAL,
      draft: true,
      purchase_disabled_at: Time.current,
      display_product_reviews: true,
      # Every variant (for example, each license) gets the same files.
      has_same_rich_content_for_all_variants: true,
      taxonomy: Taxonomy.find_by(id: attributes["taxonomy_id"]) || Taxonomy.find_by(slug: "other"),
    )

    ActiveRecord::Base.transaction do
      product.save!
      product.set_template_properties_if_needed
      product.save_tags!(attributes["tags"]) if attributes["tags"].present?
      create_variant_categories!(product)
      save_files!(product, file_urls) if file_urls.any?
    end

    product
  end

  # Returns warnings for the covers and thumbnail that were not imported.
  def attach_media(product)
    attach_covers(product) + attach_thumbnail(product)
  end

  private
    attr_reader :seller, :attributes

    def create_variant_categories!(product)
      attributes["variant_categories"].each do |category_attributes|
        category = VariantCategory.create!(link: product, title: category_attributes["title"])
        category_attributes["variants"].each do |variant_attributes|
          Variant.create!(variant_category: category, name: variant_attributes["name"], price_difference_cents: variant_attributes["price_difference_cents"])
        end
      end
    end

    # Buyers see the files that the content page embeds, so add one page with every file.
    def save_files!(product, file_urls)
      files = file_urls.each_with_index.map do |url, position|
        { url:, display_name: attributes["files"][position]["display_name"].presence, position: }.compact
      end
      SaveFilesService.perform(product, { files: })
      product.save!

      file_embeds = product.alive_product_files.sort_by(&:position).map do |product_file|
        { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => product_file.external_id, "uid" => SecureRandom.uuid } }
      end
      product.alive_rich_contents.create!(title: nil, description: file_embeds, position: 0)
      product.generate_product_files_archives!
    end

    # AssetPreview#url= reads the whole response into memory, so covers use the bounded download.
    def attach_covers(product)
      attributes["covers"].filter_map do |cover|
        PartnerMigration::RemoteFileTransfer.download(cover["url"], max_bytes: AssetPreview::MAX_IMAGE_FILE_SIZE) do |tempfile, filename|
          blob = ActiveStorage::Blob.create_and_upload!(io: tempfile, filename:, content_type: Marcel::MimeType.for(tempfile, name: filename))
          asset_preview = product.asset_previews.build
          asset_preview.file.attach(blob.signed_id)
          asset_preview.analyze_file
          asset_preview.save!
        rescue ActiveRecord::RecordInvalid
          blob&.purge
          raise
        end
        nil
      rescue *MEDIA_ERRORS => e
        product.asset_previews.reset
        "Cover #{cover["url"]} was not imported: #{e.message}"
      end
    end

    def attach_thumbnail(product)
      return [] if attributes["thumbnail_url"].blank?

      thumbnail = product.build_thumbnail
      thumbnail.url = attributes["thumbnail_url"]
      thumbnail.file.analyze if thumbnail.file.attached? && !thumbnail.file.analyzed?
      thumbnail.save!
      []
    rescue *MEDIA_ERRORS => e
      thumbnail&.file&.blob&.purge if thumbnail&.file&.attached?
      ["Thumbnail #{attributes["thumbnail_url"]} was not imported: #{e.message}"]
    end
end
