# frozen_string_literal: true

# Serves a web build's files to the player's frame, under the grant UrlRedirectsController#play
# issued. The frame is an opaque origin, so these requests carry no cookies: the grant is the only
# credential, and checking it needs no database query.
#
# Files that resolve other URLs, or that a browser can open as a page, are served from here so they
# keep the grant path. A redirected module script or stylesheet would take the CDN link as its base
# URL, and its relative imports and url()s would miss the signature. A redirected page would run as
# a gumroad.com subdomain. Every other file (wasm, images, audio, data) redirects to a signed CDN link.
class ProductBuildPlayerFilesController < ApplicationController
  include SignedUrlHelper

  INDEX = "index.html"
  HTML_EXTENSIONS = %w[html htm].freeze
  DOCUMENT_EXTENSIONS = (HTML_EXTENSIONS + %w[svg xml]).freeze
  SERVED_EXTENSIONS = (DOCUMENT_EXTENSIONS + %w[js mjs cjs css]).freeze
  MAX_SERVED_BYTE_SIZE = 25.megabytes
  # Shorter than the signed link it points at, so a cached redirect never hands out an expired link.
  CACHE_MAX_AGE = 5.minutes

  # Rails refuses a JavaScript response to a plain <script> GET, to keep it from leaking session
  # data cross-origin. These responses are the build's own files, read with no session.
  skip_forgery_protection

  before_action :verify_grant
  before_action :set_path

  def show
    # Module scripts, fetch and wasm from the frame are CORS requests with `Origin: null`, and the
    # browser checks a redirect as well as the response it leads to.
    response.set_header("Access-Control-Allow-Origin", "*")
    return serve_file if SERVED_EXTENSIONS.include?(extension)

    expires_in CACHE_MAX_AGE, public: false
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

    def serve_file
      html = HTML_EXTENSIONS.include?(extension)
      # Each page load is a new play session, so the kill switch is checked here and not per file.
      return e404 if html && !Feature.active?(:product_build_player, User.find_by(id: @grant["seller_id"]))

      s3 = Aws::S3::Client.new
      return e404 if s3.head_object(bucket: S3_BUCKET, key: s3_key).content_length > MAX_SERVED_BYTE_SIZE

      object = s3.get_object(bucket: S3_BUCKET, key: s3_key)
      body = object.body.read
      if html
        save = ProductBuildSave.find_by(purchase_id: @grant["purchase_id"])
        body = ProductBuilds::PlayerDocument.render(body, save_data: save&.data || {})
        # The page carries the buyer's save.
        response.set_header("Cache-Control", "private, no-store")
      else
        expires_in CACHE_MAX_AGE, public: false
      end

      if DOCUMENT_EXTENSIONS.include?(extension)
        SecureHeaders.opt_out_of_header(request, :csp)
        response.set_header("Content-Security-Policy", ProductBuilds::PlayerDocument.content_security_policy(request_origin: request.base_url, cdn_origin:))
      end
      # The path holds the content-page token and the grant, so it must not reach the CDN or a game's server.
      response.set_header("Referrer-Policy", "no-referrer")
      send_data body, type: object.content_type, disposition: "inline"
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      e404
    end

    def cdn_origin
      url = URI.parse(USING_MINIO ? AWS_S3_ENDPOINT : FILE_DOWNLOAD_DISTRIBUTION_URL)
      "#{url.scheme}://#{url.host}#{":#{url.port}" unless url.port == url.default_port}"
    end
end
