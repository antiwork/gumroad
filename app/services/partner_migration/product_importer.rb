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

  # `heartbeat` runs around each remote transfer, so the caller can record that the import is alive.
  def initialize(seller:, attributes:, heartbeat: -> { })
    @seller = seller
    @attributes = attributes
    @heartbeat = heartbeat
  end

  # Returns the S3 URLs of unique_files, in order. On an error, deletes the files it uploaded.
  def download_files
    @uploaded_urls = []
    unique_files.each do |file|
      heartbeat.call
      @uploaded_urls << PartnerMigration::RemoteFileTransfer.new(seller:, url: file["url"]).perform
      heartbeat.call
    end
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
      is_adult: attributes["is_adult"],
      # Without variant files, every variant (for example, each license) gets the same files.
      has_same_rich_content_for_all_variants: !variant_files?,
      taxonomy: Taxonomy.find_by(id: attributes["taxonomy_id"]) || Taxonomy.find_by(slug: "other"),
    )

    ActiveRecord::Base.transaction do
      # The partner endpoint bounds the catalog; the daily editor quota must not truncate an import.
      Link.bypass_product_creation_limit { product.save! }
      product.set_template_properties_if_needed
      product.save_tags!(attributes["tags"]) if attributes["tags"].present?
      variants = create_variant_categories!(product)
      save_files!(product, file_urls, variants) if file_urls.any?
    end

    product
  end

  # Returns warnings for the covers and thumbnail that were not imported.
  def attach_media(product)
    attach_covers(product) + attach_thumbnail(product)
  end

  private
    attr_reader :seller, :attributes, :heartbeat

    def variant_attributes_list = attributes["variant_categories"].flat_map { _1["variants"] }

    def variant_files? = variant_attributes_list.any? { _1["files"] }

    # The files of the product and its variants, each URL once, so a file that several licenses share
    # downloads once.
    def unique_files
      @unique_files ||= (attributes["files"] + variant_attributes_list.flat_map { _1["files"].to_a }).uniq { _1["url"] }
    end

    # Returns [variant, its attributes] pairs.
    def create_variant_categories!(product)
      attributes["variant_categories"].flat_map do |category_attributes|
        category = VariantCategory.create!(link: product, title: category_attributes["title"])
        category_attributes["variants"].map do |variant_attributes|
          variant = Variant.create!(variant_category: category, name: variant_attributes["name"], description: variant_attributes["description"], price_difference_cents: variant_attributes["price_difference_cents"])
          [variant, variant_attributes]
        end
      end
    end

    # Buyers see the files that the content pages embed. Without variant files, one product page embeds
    # every file. With them, each variant gets a page with its own files, or with the product's files.
    def save_files!(product, file_urls, variants)
      files = file_urls.each_with_index.map do |url, position|
        { url:, display_name: unique_files[position]["display_name"].presence, position: }.compact
      end
      SaveFilesService.perform(product, { files: })
      product.save!

      product_files = unique_files.map { _1["url"] }.zip(product.alive_product_files.sort_by(&:position)).to_h
      if variant_files?
        variants.each do |variant, variant_attributes|
          variant_product_files = (variant_attributes["files"] || attributes["files"]).map { product_files.fetch(_1["url"]) }
          next if variant_product_files.empty?

          variant.product_files = variant_product_files
          variant.alive_rich_contents.create!(title: nil, description: file_embeds(variant_product_files), position: 0)
        end
      else
        product.alive_rich_contents.create!(title: nil, description: file_embeds(product_files.values), position: 0)
      end
      product.generate_product_files_archives!
    end

    def file_embeds(product_files)
      product_files.map { { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => _1.external_id, "uid" => SecureRandom.uuid } } }
    end

    # AssetPreview#url= reads the whole response into memory, so covers use the bounded download.
    def attach_covers(product)
      attributes["covers"].filter_map do |cover|
        heartbeat.call
        PartnerMigration::RemoteFileTransfer.download(cover["url"], max_bytes: AssetPreview::MAX_IMAGE_FILE_SIZE) do |tempfile, filename|
          blob = ActiveStorage::Blob.create_and_upload!(io: tempfile, filename:, content_type: Marcel::MimeType.for(tempfile, name: filename))
          asset_preview = product.asset_previews.build
          asset_preview.file.attach(blob.signed_id)
          asset_preview.analyze_file
          asset_preview.save!
        rescue StandardError
          # Nothing keeps a blob that is not saved.
          blob&.purge
          raise
        end
        nil
      rescue *MEDIA_ERRORS => e
        product.asset_previews.reset
        "Cover #{cover["url"]} was not imported: #{e.message}"
      end
    end

    # Thumbnail#url= limits the size but not the time, so the thumbnail also uses the bounded download.
    def attach_thumbnail(product)
      return [] if attributes["thumbnail_url"].blank?

      heartbeat.call
      PartnerMigration::RemoteFileTransfer.download(attributes["thumbnail_url"], max_bytes: Thumbnail::MAX_FILE_SIZE) do |tempfile, filename|
        blob = ActiveStorage::Blob.create_and_upload!(io: tempfile, filename:, content_type: Marcel::MimeType.for(tempfile, name: filename))
        thumbnail = product.build_thumbnail
        thumbnail.file.attach(blob.signed_id)
        thumbnail.file.analyze
        thumbnail.save!
      rescue StandardError
        # Nothing keeps a blob that is not saved.
        blob&.purge
        raise
      end
      []
    rescue *MEDIA_ERRORS => e
      ["Thumbnail #{attributes["thumbnail_url"]} was not imported: #{e.message}"]
    end
end
