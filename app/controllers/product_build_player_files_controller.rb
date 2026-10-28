# frozen_string_literal: true

# Serves a web build's files to the player's frame, under the grant UrlRedirectsController#play
# issued. The frame is an opaque origin, so these requests carry no cookies: the grant is the only
# credential, and checking it needs no database query.
#
# Most files redirect to a signed CDN link. Files a browser can open as a page never do: on the
# CDN host they would run as a gumroad.com subdomain. They are served from here, with the CSP that
# sandboxes them even when the URL is opened outside the frame.
class ProductBuildPlayerFilesController < ApplicationController
  include SignedUrlHelper

  INDEX = "index.html"
  DOCUMENT_EXTENSIONS = %w[html htm svg xml].freeze
  HTML_EXTENSIONS = %w[html htm].freeze
  MAX_DOCUMENT_BYTE_SIZE = 10.megabytes
  # Shorter than the signed link it points at, so a cached redirect never hands out an expired link.
  REDIRECT_MAX_AGE = 5.minutes

  before_action :verify_grant
  before_action :set_path

  def show
    return render_document if DOCUMENT_EXTENSIONS.include?(extension)

    # Module scripts, fetch and wasm from the frame are CORS requests with `Origin: null`, and the
    # browser checks the redirect as well as the CDN response.
    response.set_header("Access-Control-Allow-Origin", "*")
    expires_in REDIRECT_MAX_AGE, public: false
    redirect_to signed_build_site_url(s3_key), allow_other_host: true
  end

  private
    def verify_grant
      @grant = ProductBuild.verified_player_grant(params[:grant], url_redirect_token: params[:id])
      e404 if @grant.nil?
    end

    def set_path
      path = params[:path].presence || INDEX
      segments = path.split("/")
      e404 if segments.empty? || segments.any? { _1.empty? || _1 == "." || _1 == ".." } || path.match?(/[\p{Cc}\\]/)
      @path = path
    end

    def extension = File.extname(@path).delete_prefix(".").downcase

    def s3_key = "#{@grant["site_prefix"]}/#{@path}"

    # Each page load is a new play session, so the kill switch is checked here and not per file.
    def render_document
      return e404 unless Feature.active?(:product_build_player, User.find_by(id: @grant["seller_id"]))

      s3 = Aws::S3::Client.new
      return e404 if s3.head_object(bucket: S3_BUCKET, key: s3_key).content_length > MAX_DOCUMENT_BYTE_SIZE

      object = s3.get_object(bucket: S3_BUCKET, key: s3_key)
      body = object.body.read
      if HTML_EXTENSIONS.include?(extension)
        save = ProductBuildSave.find_by(purchase_id: @grant["purchase_id"])
        body = ProductBuilds::PlayerDocument.render(body, save_data: save&.data || {})
      end

      SecureHeaders.opt_out_of_header(request, :csp)
      response.set_header("Content-Security-Policy", ProductBuilds::PlayerDocument.content_security_policy(request_origin: request.base_url, cdn_origin:))
      # The path holds the content-page token and the grant, so it must not reach the CDN or a game's server.
      response.set_header("Referrer-Policy", "no-referrer")
      # The page carries the buyer's save.
      response.set_header("Cache-Control", "private, no-store")
      send_data body, type: object.content_type, disposition: "inline"
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      e404
    end

    def cdn_origin
      url = URI.parse(USING_MINIO ? AWS_S3_ENDPOINT : FILE_DOWNLOAD_DISTRIBUTION_URL)
      "#{url.scheme}://#{url.host}#{":#{url.port}" unless url.port == url.default_port}"
    end
end
