# frozen_string_literal: true

# Deploy pipeline for browser games. The caller uploads a zip through
# POST /v2/files/presign + /complete, then `deploy` copies it into an immutable,
# numbered build. Nothing reaches buyers until `promote`.
class Api::V2::GameBuildsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_products }
  before_action :fetch_product
  before_action :set_build, only: [:show, :promote]

  def index
    render_response(true, game_builds: @product.game_builds.map { build_json(_1) })
  end

  def show
    render_response(true, game_build: build_json(@build))
  end

  def deploy
    url = params[:url]
    return render_response(false, message: "url is required.") unless url.is_a?(String) && url.present?

    seller_prefix = "#{S3_BASE_URL}attachments/#{current_resource_owner.external_id}/"
    if !url.start_with?(seller_prefix) || url.include?("..") || url.match?(/%2f/i) || !url.end_with?(".zip")
      return render_response(false, message: "url must be a .zip you uploaded with POST /v2/files/presign and /v2/files/complete.")
    end

    existing = @product.game_builds.find_by(source_url: url)
    return render_response(true, game_build: build_json(existing)) if existing

    return render_response(false, message: "This product already has #{GameBuild::MAX_BUILDS_PER_PRODUCT} builds.") if @product.game_builds.count >= GameBuild::MAX_BUILDS_PER_PRODUCT

    source_key = url.delete_prefix(S3_BASE_URL)
    head = Aws::S3::Client.new.head_object(bucket: S3_BUCKET, key: source_key)
    return render_response(false, message: "The uploaded zip is empty or larger than #{GameBuild::MAX_BYTE_SIZE / 1.gigabyte} GB.") unless head.content_length.between?(1, GameBuild::MAX_BYTE_SIZE)

    build = @product.with_lock do
      number = (@product.game_builds.maximum(:number) || 0) + 1
      key = GameBuild.storage_key_for(@product.id, number)
      Aws::S3::Client.new.copy_object(bucket: S3_BUCKET, key:, copy_source: "#{S3_BUCKET}/#{source_key}", metadata_directive: "REPLACE", content_type: "application/zip")
      @product.game_builds.create!(number:, source_url: url, storage_key: key, byte_size: head.content_length)
    end

    render_response(true, game_build: build_json(build))
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    render_response(false, message: "The uploaded zip was not found. Finish the upload with POST /v2/files/complete first.")
  rescue Aws::S3::Errors::ServiceError => e
    error_400(e.message)
  rescue ActiveRecord::RecordNotUnique
    render_response(true, game_build: build_json(@product.game_builds.find_by!(source_url: url)))
  end

  def promote
    @build.promote!
    render_response(true, game_build: build_json(@build.reload))
  end

  private
    def set_build
      @build = @product.game_builds.find_by_external_id(params[:id]) || error_with_object(:game_build, nil)
    end

    def build_json(build)
      {
        id: build.external_id,
        number: build.number,
        status: build.status,
        byte_size: build.byte_size,
        created_at: build.created_at,
        promoted_at: build.promoted_at,
      }
    end
end
