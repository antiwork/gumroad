# frozen_string_literal: true

class ProductFilesUtilityController < ApplicationController
  include SignedUrlHelper

  before_action :authenticate_user!

  before_action :set_product, only: %i[download_product_files download_folder_archive]

  def external_link_title
    response = SsrfFilter.get(params.require(:url))
    title = Nokogiri::HTML(response.body).title
    title = "Untitled" if title.blank?

    render json: {
      success: true,
      title:
    }
  rescue
    render json: { success: false }
  end

  def download_product_files
    product_files = current_seller.alive_product_files_preferred_for_product(@product).by_external_ids(params[:product_file_ids])
    e404 if product_files.blank?

    url_redirect = @product.url_redirects.build
    if request.format.json?
      render(json: { files: product_files.map { { url: url_redirect.signed_location_for_file(_1), filename: _1.s3_filename } } })
    else
      # Non-JSON requests to this controller route pass an array with a single product file ID for `product_file_ids`
      redirect_to(url_redirect.signed_location_for_file(product_files.first), allow_other_host: true)
    end
  end

  def download_folder_archive
    variant = @product.alive_variants.find_by_external_id(params[:variant_id]) if params[:variant_id].present?
    archive = (variant || @product).product_files_archives.latest_ready_folder_archive(params[:folder_id])

    if request.format.json?
      # The frontend appends Google Analytics query parameters to the signed S3 URL
      # in staging and production (which breaks the URL), so we instead return the
      # controller route that can be used to be redirected to the signed URL
      url = download_folder_archive_url(params[:folder_id], { variant_id: params[:variant_id], product_id: params[:product_id] }) if archive.present?
      render json: { url: }
    else
      e404 if archive.nil?
      redirect_to(signed_download_url_for_s3_key_and_filename(archive.s3_key, archive.s3_filename), allow_other_host: true)
    end
  end

  private
    def set_product
      @product = current_seller.products.find_by_external_id(params[:product_id])
      e404 if @product.nil?

      authorize @product, :edit?
    end
end
