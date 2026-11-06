# frozen_string_literal: true

# Copies a zip the seller uploaded into a new, immutable, numbered build of the product. Nothing
# reaches buyers until the build is promoted. Deploying the same upload again returns its build.
class ProductBuilds::DeployService
  class DeployError < StandardError; end

  def self.perform(product:, seller:, url:) = new(product:, seller:, url:).perform

  def initialize(product:, seller:, url:)
    @product = product
    @seller = seller
    @url = url
  end

  def perform
    raise DeployError, "url is required." unless @url.is_a?(String) && @url.present?

    seller_prefix = "#{S3_BASE_URL}attachments/#{@seller.external_id}/"
    if !@url.start_with?(seller_prefix) || @url.include?("..") || @url.match?(/%2f/i) || !@url.downcase.end_with?(".zip")
      raise DeployError, "url must be a .zip you uploaded with POST /v2/files/presign and /v2/files/complete."
    end

    existing = @product.product_builds.find_by(source_url: @url)
    return existing if existing

    check_free_product_allowed!

    source_key = @url.delete_prefix(S3_BASE_URL)
    head = Aws::S3::Client.new.head_object(bucket: S3_BUCKET, key: source_key)
    raise DeployError, "The uploaded zip is empty or larger than #{ProductBuild::MAX_BYTE_SIZE / 1.gigabyte} GB." unless head.content_length.between?(1, ProductBuild::MAX_BYTE_SIZE)

    # Checks and the copy happen under the product lock so concurrent deploys cannot pass the
    # limit together or copy the same upload twice.
    build = with_seller_limits do
      @product.with_lock do
        existing = @product.product_builds.find_by(source_url: @url)
        next existing if existing
        next if @product.product_builds.count >= ProductBuild::MAX_BUILDS_PER_PRODUCT

        number = (@product.product_builds.maximum(:number) || 0) + 1
        key = ProductBuild.storage_key_for(@product.id, number)
        Aws::S3::Client.new.copy_object(bucket: S3_BUCKET, key:, copy_source: "#{S3_BUCKET}/#{Seahorse::Util.uri_path_escape(source_key)}", metadata_directive: "REPLACE", content_type: "application/zip")
        @product.product_builds.create!(number:, source_url: @url, storage_key: key, byte_size: head.content_length)
      end
    end
    raise DeployError, "This product already has #{ProductBuild::MAX_BUILDS_PER_PRODUCT} builds." unless build

    build
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    raise DeployError, "The uploaded zip was not found. Finish the upload with POST /v2/files/complete first."
  end

  private
    # An unproven seller gets paid products only, and a daily cap across all their products. The
    # count and the create share the seller's row lock so concurrent deploys cannot both pass it.
    def with_seller_limits
      owner = @product.user
      return yield unless ContentModeration::GumroadImpersonation.unproven_seller?(owner)

      owner.with_lock do
        recent = ProductBuild.joins(:product).where(links: { user_id: owner.id }).where("product_builds.created_at > ?", 1.day.ago).count
        if recent >= ProductBuild::MAX_DAILY_BUILDS_FOR_UNPROVEN_SELLER
          raise DeployError, "New accounts can upload #{ProductBuild::MAX_DAILY_BUILDS_FOR_UNPROVEN_SELLER} builds a day. Try again tomorrow."
        end

        yield
      end
    end

    def check_free_product_allowed!
      return unless ContentModeration::GumroadImpersonation.unproven_seller?(@product.user)
      return unless ProductBuild.free_product?(@product)

      raise DeployError, "Web builds on free products are available once your account is #{ContentModeration::GumroadImpersonation::PROVEN_ACCOUNT_AGE.in_days.to_i} days old or has made a paid sale. You can add a build to a paid product now."
    end
end
