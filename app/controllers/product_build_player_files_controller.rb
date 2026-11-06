# frozen_string_literal: true

# Serves a web build's files to the player's frame, under the grant UrlRedirectsController#play
# issued. The frame is an opaque origin, so these requests carry no cookies: the grant is the only
# credential, and checking it needs no database query. ProductBuildDemoFilesController serves a
# public demo the same way.
#
# Files that resolve other URLs, or that a browser can open as a page, are served from here so they
# keep the grant path. A redirected module script or stylesheet would take the CDN link as its base
# URL, and its relative imports and url()s would miss the signature. A redirected page would run as
# a gumroad.com subdomain. Every other file (wasm, images, audio, data) redirects to a signed CDN link.
class ProductBuildPlayerFilesController < ApplicationController
  include SignedUrlHelper

  INDEX = "index.html"
  SERVED_EXTENSIONS = (ProductBuild::PAGE_EXTENSIONS + %w[svg xml js mjs cjs css]).freeze
  # Shorter than the signed link it points at, so a cached redirect never hands out an expired link.
  CACHE_MAX_AGE = 5.minutes
  # Room for a full save as JSON, where escaping can turn one byte into six (\u0001), plus the batch's
  # own fields; ProductBuildSave enforces the real limits.
  MAX_SAVE_REQUEST_BYTES = ProductBuildSave::MAX_BYTE_SIZE * 6 + 64.kilobytes

  # Rails refuses a JavaScript response to a plain <script> GET, to keep it from leaking session
  # data cross-origin. These responses are the build's own files, read with no session.
  skip_forgery_protection
  # The seller writes these files, so the visitor's CSRF token must never be written into them.
  skip_after_action :inject_csrf_token

  before_action :verify_grant, only: :show
  before_action :verify_save_grant, only: :save
  before_action :verify_heartbeat_grant, only: :heartbeat
  before_action :set_path, only: :show

  def show
    # Module scripts, fetch and wasm from the frame are CORS requests with `Origin: null`, and the
    # browser checks a redirect as well as the response it leads to.
    response.set_header("Access-Control-Allow-Origin", "*")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
    return serve_file if SERVED_EXTENSIONS.include?(extension)

    expires_in CACHE_MAX_AGE, public: false
    redirect_to signed_build_site_location(s3_key), allow_other_host: true
  end

  # A batch from the frame's save shim. The body is text/plain JSON, the one type a beacon can send
  # without a CORS preflight, and the shim reads the status, so the response allows any origin.
  def save
    response.set_header("Access-Control-Allow-Origin", "*")
    return head :payload_too_large if request.content_length.to_i > MAX_SAVE_REQUEST_BYTES

    changes = JSON.parse(request.raw_post)
    return head :unprocessable_entity unless changes.is_a?(Hash)

    ProductBuildSave.apply_changes!(
      Purchase.find(@grant["purchase_id"]),
      set: changes.fetch("set", {}),
      remove: changes.fetch("remove", []),
      clear: changes.fetch("clear", false),
      writer: changes["writer"],
      sequence: changes["sequence"],
    )
    head :no_content
  rescue JSON::ParserError, ProductBuildSave::LimitError
    head :unprocessable_entity
  end

  # The player page is open: extend the play session its page load started. The page stops sending
  # these when the buyer leaves, which is what ends the session (see ProductBuildPlaySession). A beat
  # that resumed an expired session answers with the new session's heartbeat path.
  def heartbeat
    session = @play_session.heartbeat!
    return head :no_content if session == @play_session

    grant = session.product_build.player_heartbeat_grant(url_redirect_token: params[:id], purchase_id: session.purchase_id, session_id: session.id)
    render json: { heartbeat_path: "/d/#{params[:id]}/play/#{grant}/heartbeat" }
  end

  private
    def verify_grant
      @grant = ProductBuild.verified_player_grant(params[:grant], url_redirect_token: params[:id], purpose: grant_purpose)
      e404 if @grant.nil?
    end

    def grant_purpose = ProductBuild::PLAYER_GRANT_PURPOSE

    # Each page load is a new play session, so this is checked per page and not per file.
    def page_allowed? = Feature.active?(:product_build_player, User.find_by(id: @grant["seller_id"]))

    # Origins besides the app that may frame the player page.
    def frame_ancestors = []

    def save_data = ProductBuildSave.find_by(purchase_id: @grant["purchase_id"])&.data || {}

    def save_endpoint
      "/d/#{params[:id]}/play/#{ProductBuild.player_save_grant(url_redirect_token: params[:id], purchase_id: @grant["purchase_id"])}/save"
    end

    def verify_save_grant
      @grant = ProductBuild.verified_player_grant(params[:grant], url_redirect_token: params[:id], purpose: ProductBuild::PLAYER_SAVE_GRANT_PURPOSE)
      e404 if @grant.nil?
    end

    def verify_heartbeat_grant
      @grant = ProductBuild.verified_player_grant(params[:grant], url_redirect_token: params[:id], purpose: ProductBuild::PLAYER_HEARTBEAT_GRANT_PURPOSE)
      e404 if @grant.nil?

      @play_session = ProductBuildPlaySession.find_by(id: @grant["session_id"], purchase_id: @grant["purchase_id"])
      e404 if @play_session.nil?
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
      page = ProductBuild::PAGE_EXTENSIONS.include?(extension)
      return e404 if page && !page_allowed?

      s3 = Aws::S3::Client.new
      head = s3.head_object(bucket: S3_BUCKET, key: s3_key)
      # On every file, not just documents: whatever a file turns out to be, opening its URL directly
      # must never run it on the app's origin.
      SecureHeaders.opt_out_of_header(request, :csp)
      response.set_header("Content-Security-Policy", ProductBuilds::PlayerDocument.content_security_policy(request_origin: request.base_url, cdn_origin:, frame_ancestors:))
      # The path holds the content-page token and the grant, so it must not reach the CDN or a game's server.
      response.set_header("Referrer-Policy", "no-referrer")
      page ? serve_page(s3, head) : stream_file(s3, head)
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      e404
    end

    def serve_page(s3, head)
      # The unpack rejects larger pages; this guards pages unpacked before that limit.
      return e404 if head.content_length > ProductBuild::MAX_PAGE_BYTE_SIZE

      body = ProductBuilds::PlayerDocument.render(s3.get_object(bucket: S3_BUCKET, key: s3_key).body.read, save_data:, save_url: save_endpoint)
      # The page carries the buyer's save.
      response.set_header("Cache-Control", "private, no-store")
      send_data body, type: ProductBuild.content_type_for(@path), disposition: "inline"
    end

    # Streamed, not read into memory: a bundled script can be as large as the build allows.
    def stream_file(s3, head)
      expires_in CACHE_MAX_AGE, public: false
      response.set_header("Content-Type", ProductBuild.content_type_for(@path))
      response.set_header("Content-Length", head.content_length.to_s)
      key = s3_key
      self.response_body = Enumerator.new do |chunks|
        s3.get_object(bucket: S3_BUCKET, key:) { |chunk| chunks << chunk }
      end
    end

    def cdn_origin
      url = URI.parse(USING_MINIO ? AWS_S3_ENDPOINT : FILE_DOWNLOAD_DISTRIBUTION_URL)
      "#{url.scheme}://#{url.host}#{":#{url.port}" unless url.port == url.default_port}"
    end
end
