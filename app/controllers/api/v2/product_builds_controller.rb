# frozen_string_literal: true

# Deploy pipeline for hosted web builds (games, interactive courses). The caller uploads
# a zip through POST /v2/files/presign + /complete, then `deploy` copies it into an
# immutable, numbered build. Nothing reaches buyers until `promote`.
class Api::V2::ProductBuildsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_products }
  before_action :fetch_product
  before_action :set_build, only: [:show, :promote]

  def index
    render_response(true, builds: @product.product_builds.map { build_json(_1) })
  end

  def show
    render_response(true, build: build_json(@build))
  end

  def deploy
    url = params[:url]
    return render_response(false, message: "url is required.") unless url.is_a?(String) && url.present?

    seller_prefix = "#{S3_BASE_URL}attachments/#{current_resource_owner.external_id}/"
    if !url.start_with?(seller_prefix) || url.include?("..") || url.match?(/%2f/i) || !url.end_with?(".zip")
      return render_response(false, message: "url must be a .zip you uploaded with POST /v2/files/presign and /v2/files/complete.")
    end

    existing = @product.product_builds.find_by(source_url: url)
    return render_response(true, build: build_json(existing)) if existing

    source_key = url.delete_prefix(S3_BASE_URL)
    head = Aws::S3::Client.new.head_object(bucket: S3_BUCKET, key: source_key)
    return render_response(false, message: "The uploaded zip is empty or larger than #{ProductBuild::MAX_BYTE_SIZE / 1.gigabyte} GB.") unless head.content_length.between?(1, ProductBuild::MAX_BYTE_SIZE)

    # Checks and the copy happen under the product lock so concurrent deploys cannot pass the
    # limit together or copy the same upload twice.
    build = @product.with_lock do
      existing = @product.product_builds.find_by(source_url: url)
      next existing if existing
      next if @product.product_builds.count >= ProductBuild::MAX_BUILDS_PER_PRODUCT

      number = (@product.product_builds.maximum(:number) || 0) + 1
      key = ProductBuild.storage_key_for(@product.id, number)
      Aws::S3::Client.new.copy_object(bucket: S3_BUCKET, key:, copy_source: "#{S3_BUCKET}/#{Seahorse::Util.uri_path_escape(source_key)}", metadata_directive: "REPLACE", content_type: "application/zip")
      @product.product_builds.create!(number:, source_url: url, storage_key: key, byte_size: head.content_length)
    end
    return render_response(false, message: "This product already has #{ProductBuild::MAX_BUILDS_PER_PRODUCT} builds.") unless build

    render_response(true, build: build_json(build))
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    render_response(false, message: "The uploaded zip was not found. Finish the upload with POST /v2/files/complete first.")
  rescue Aws::S3::Errors::ServiceError => e
    error_400(e.message)
  end

  def promote
    @build.promote!
    render_response(true, build: build_json(@build.reload))
  end

  private
    def set_build
      @build = @product.product_builds.find_by(public_id: params[:id].to_s) || error_with_object(:build, nil)
    end

    def build_json(build)
      {
        id: build.public_id,
        number: build.number,
        status: build.status,
        byte_size: build.byte_size,
        created_at: build.created_at,
        promoted_at: build.promoted_at,
      }
    end
end
