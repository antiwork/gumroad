# frozen_string_literal: true

class UrlRedirectsController < ApplicationController
  include SignedUrlHelper
  include ProductsHelper
  include PageMeta::Favicon

  layout "inertia", only: [:expired, :rental_expired_page, :membership_inactive_page, :confirm_page, :read, :stream, :download_page]

  before_action :fetch_url_redirect, except: %i[
    show stream download_subtitle_file read download_archive download_product_files
  ]
  before_action :redirect_to_custom_domain_if_needed, only: :download_page
  before_action :redirect_bundle_purchase_to_library_if_needed, only: :download_page
  before_action :redirect_to_coffee_page_if_needed, only: :download_page
  before_action :check_permissions, only: %i[show stream download_page
                                             hls_playlist download_subtitle_file read
                                             download_archive download_product_files
                                             save_last_content_page]
  before_action :hide_layouts, only: %i[
    show download_product_files smil hls_playlist download_subtitle_file
  ]
  before_action :mark_rental_as_viewed, only: %i[smil hls_playlist]
  after_action :register_that_user_has_downloaded_product, only: %i[download_page show stream read]
  after_action -> { create_consumption_event!(ConsumptionEvent::EVENT_TYPE_READ) }, only: [:read]
  after_action -> { create_consumption_event!(ConsumptionEvent::EVENT_TYPE_WATCH) }, only: [:hls_playlist, :smil]
  after_action -> { create_consumption_event!(ConsumptionEvent::EVENT_TYPE_DOWNLOAD) }, only: [:show]
  after_action -> { create_download_page_view_consumption_event! }, only: [:download_page]

  skip_before_action :check_suspended, only: %i[show stream confirm confirm_page download_page
                                                download_subtitle_file download_archive download_product_files]
  before_action :set_noindex_header, only: %i[confirm_page download_page]

  rescue_from ActionController::RoutingError do |exception|
    if params[:action] == "read"
      redirect_to user_signed_in? ? library_path : root_path
    else
      raise exception
    end
  end

  module AddToLibraryOption
    NONE = "none"
    ADD_TO_LIBRARY_BUTTON = "add_to_library_button"
    SIGNUP_FORM = "signup_form"
  end

  def show
    trigger_files_lifecycle_events
    redirect_to @url_redirect.redirect_or_s3_location, allow_other_host: true
  end

  def read
    product = @url_redirect.referenced_link
    @product_file = @url_redirect.product_file(params[:product_file_id])
    @product_file = product.product_files.alive.find(&:readable?) if product.present? && @product_file.nil?
    e404 unless @product_file&.readable?

    s3_retrievable = @product_file
    title = @product_file.with_product_files_owner.name
    set_meta_tag(title:)
    read_url = signed_download_url_for_s3_key_and_filename(s3_retrievable.s3_key, s3_retrievable.s3_filename, cache_group: "read")

    trigger_files_lifecycle_events

    render inertia: "UrlRedirects/Read", props: UrlRedirectPresenter.new(url_redirect: @url_redirect, logged_in_user:).read_page_props(
      product_file: @product_file,
      read_url:,
      title:,
    )
  rescue ArgumentError
    redirect_to(library_path)
  end

  def download_page
    if download_page_polling_request?
      props = requested_download_page_polling_props
      return render(inertia: "UrlRedirects/DownloadPage", props:)
    end

    set_download_page_meta_tags
    trigger_files_lifecycle_events

    presenter = UrlRedirectPresenter.new(url_redirect: @url_redirect, logged_in_user:)
    props = presenter.download_page_with_content_props(common_props).merge(
      audio_durations: InertiaRails.optional { audio_durations_data },
      latest_media_locations: InertiaRails.optional { latest_media_locations_data },
      dropbox_api_key: DROPBOX_PICKER_API_KEY,
    )

    render inertia: "UrlRedirects/DownloadPage", props:
  end

  def download_product_files
    product_files = @url_redirect.alive_product_files.by_external_ids(params[:product_file_ids])
    e404 unless product_files.present? && product_files.all? { @url_redirect.is_file_downloadable?(_1) }

    if request.format.json?
      render(json: { files: product_files.map { { url: @url_redirect.signed_location_for_file(_1), filename: _1.s3_filename } } })
    else
      # Non-JSON requests to this controller route pass an array with a single product file ID for `product_file_ids`
      @product_file = product_files.first

      if @product_file.must_be_pdf_stamped? && @url_redirect.missing_stamped_pdf?(@product_file)
        flash[:warning] = "We are preparing the file for download. You will receive an email when it is ready."

        # Do not enqueue the job more than once in 2 hours
        Rails.cache.fetch(PdfStampingService.cache_key_for_purchase(@url_redirect.purchase_id), expires_in: 4.hours) do
          StampPdfForPurchaseJob.set(queue: :critical).perform_async(@url_redirect.purchase_id, true) # Stamp and notify the buyer
        end

        return redirect_to(@url_redirect.download_page_url)
      end

      redirect_to(@url_redirect.signed_location_for_file(@product_file), allow_other_host: true)
      create_consumption_event!(ConsumptionEvent::EVENT_TYPE_DOWNLOAD)
    end
  end

  def download_archive
    archive = params[:folder_id].present? ? @url_redirect.folder_archive(params[:folder_id]) : @url_redirect.entity_archive

    if request.format.json?
      url = url_redirect_download_archive_url(params[:id], folder_id: params[:folder_id]) if archive.present?
      render json: { url: }
    else
      e404 if archive.nil?
      redirect_to(
        signed_download_url_for_s3_key_and_filename(archive.s3_key, archive.s3_filename),
        allow_other_host: true
      )
      event_type = params[:folder_id].present? ? ConsumptionEvent::EVENT_TYPE_FOLDER_DOWNLOAD : ConsumptionEvent::EVENT_TYPE_DOWNLOAD_ALL
      create_consumption_event!(event_type)
    end
  end

  def download_subtitle_file
    (product_file = @url_redirect.product_file(params[:product_file_id])) || e404
    e404 unless @url_redirect.is_file_downloadable?(product_file)
    (subtitle_file = product_file.subtitle_files.alive.find_by_external_id(params[:subtitle_file_id])) || e404

    redirect_to @url_redirect.signed_video_url(subtitle_file), allow_other_host: true
  end

  def smil
    @product_file = @url_redirect.product_file(params[:product_file_id])
    e404 if @product_file.blank?

    render plain: @url_redirect.smil_xml_for_product_file(@product_file), content_type: Mime[:text]
  end

  # Public: Returns a modified version of the Elastic Transcoder-generated master playlist in order to prevent hotlinking.
  #
  # The original master playlist simply has relative paths to the resolution-specific playlists and works by the assumption that all playlist
  # files and .ts segments are public. This makes it easy for anyone to hotlink the video by posting the path to either of the playlist files.
  # The ideal way to prevent that is to use AES encryption, which Elastic Transcoder doesn't yet support. We instead make the playlist files private
  # and provide signed urls to these playlist files.
  def hls_playlist
    (@product_file = @url_redirect.product_file(params[:product_file_id]) || @url_redirect.alive_product_files.first) || e404
    hls_playlist_data = @product_file.hls_playlist
    e404 if hls_playlist_data.blank?
    render plain: hls_playlist_data, content_type: "application/x-mpegurl"
  end

  def confirm_page
    @content_unavailability_reason_code = UrlRedirectPresenter::CONTENT_UNAVAILABILITY_REASON_CODES[:email_confirmation_required]
    set_meta_tag(title: "#{@url_redirect.referenced_link.name} - Confirm email")
    extra_props = common_props.merge(
      confirmation_info: {
        id: @url_redirect.token,
        destination: params[:destination].presence || (@url_redirect.rich_content_json.present? ? "download_page" : nil),
        display: params[:display],
        email: params[:email],
      },
    )
    props = UrlRedirectPresenter.new(url_redirect: @url_redirect, logged_in_user:).download_page_without_content_props(extra_props)

    render inertia: "UrlRedirects/ConfirmPage", props: props
  end

  def expired
    set_meta_tag(title: "#{@url_redirect.referenced_link.name} - Access expired")
    render inertia: "UrlRedirects/Expired", props: unavailable_page_props(:access_expired)
  end

  def rental_expired_page
    set_meta_tag(title: "#{@url_redirect.referenced_link.name} - Your rental has expired")
    render inertia: "UrlRedirects/RentalExpired", props: unavailable_page_props(:rental_expired)
  end

  def membership_inactive_page
    set_meta_tag(title: "#{@url_redirect.referenced_link.name} - Your membership is inactive")
    render inertia: "UrlRedirects/MembershipInactive", props: unavailable_page_props(:inactive_membership)
  end

  def change_purchaser
    if params[:email].blank? || !ActiveSupport::SecurityUtils.secure_compare(params[:email].strip.downcase, @url_redirect.purchase.email.strip.downcase)
      flash[:alert] = "Please enter the correct email address used to purchase this product"
      return redirect_to url_redirect_check_purchaser_path({ id: @url_redirect.token, next: params[:next].presence }.compact)
    end

    purchase = @url_redirect.purchase
    purchase.purchaser = logged_in_user
    purchase.save!
    redirect_to_next
  end

  def confirm
    forwardable_query_params = {}
    forwardable_query_params[:display] = params[:display] if params[:display].present?
    if @url_redirect.purchase.email.casecmp(params[:email].to_s.strip.downcase).zero?
      set_confirmed_redirect_cookie
      if params[:destination] == "download_page"
        redirect_to url_redirect_download_page_path(@url_redirect.token, **forwardable_query_params)
      elsif params[:destination] == "stream"
        redirect_to url_redirect_stream_page_path(@url_redirect.token, **forwardable_query_params)
      else
        redirect_to url_redirect_path(@url_redirect.token, **forwardable_query_params)
      end
    else
      flash[:alert] = "Wrong email. Please try again."
      redirect_to confirm_page_path(id: @url_redirect.token, **forwardable_query_params)
    end
  end

  def send_to_kindle
    return render json: { success: false, error: "Please enter a valid Kindle email address" } if params[:email].blank?

    if logged_in_user.present?
      logged_in_user.kindle_email = params[:email]
      return render json: { success: false, error: logged_in_user.errors.full_messages.to_sentence } unless logged_in_user.save
    end

    @product_file = ProductFile.find_by_external_id(params[:file_external_id])
    begin
      @product_file.send_to_kindle(params[:email])
      create_consumption_event!(ConsumptionEvent::EVENT_TYPE_READ)
      render json: { success: true }
    rescue ArgumentError => e
      render json: { success: false, error: e.message }
    end
  end

  # Consumption event is created by front-end code
  def stream
    set_meta_tag(title: "Watch")
    product_file = @url_redirect.product_file(params[:product_file_id]) || @url_redirect.alive_product_files.find(&:streamable?)
    e404 unless product_file&.streamable?

    render inertia: "UrlRedirects/Stream", props: UrlRedirectPresenter.new(url_redirect: @url_redirect, logged_in_user:).stream_page_props(product_file:)
  end

  def media_urls
    return render json: {} if params[:file_ids].blank?

    json = @url_redirect.alive_product_files.by_external_ids(params[:file_ids]).each_with_object({}) do |product_file, hash|
      urls = []
      urls << @url_redirect.hls_playlist_or_smil_xml_path(product_file) if product_file.streamable?
      urls << @url_redirect.signed_location_for_file(product_file) if product_file.listenable? || product_file.streamable?
      hash[product_file.external_id] = urls
    end

    render json:
  end

  def save_last_content_page
    return render json: { success: false, error: "Purchase not found" }, status: :unprocessable_entity if @url_redirect.purchase.blank?

    @url_redirect.purchase.update!(last_content_page_id: params[:page_id])
    render json: { success: true }
  end

  private
    def trigger_files_lifecycle_events
      @url_redirect.update_transcoded_videos_last_accessed_at
      @url_redirect.enqueue_job_to_regenerate_deleted_transcoded_videos
    end

    def redirect_to_custom_domain_if_needed
      return if Feature.inactive?(:custom_domain_download)

      creator_subdomain_with_protocol = @url_redirect.seller.subdomain_with_protocol
      target_host = !@is_user_custom_domain && creator_subdomain_with_protocol.present? ? creator_subdomain_with_protocol : request.host
      return if target_host == request.host

      redirect_to(
        custom_domain_download_page_url(@url_redirect.token, host: target_host, receipt: params[:receipt]),
        status: :moved_permanently,
        allow_other_host: true
      )
    end

    def redirect_bundle_purchase_to_library_if_needed
      return unless @url_redirect.purchase&.is_bundle_purchase?

      redirect_to library_url(bundles: @url_redirect.purchase.link.external_id, purchase_id: params[:receipt] && @url_redirect.purchase.external_id)
    end

    def redirect_to_coffee_page_if_needed
      return unless @url_redirect.referenced_link&.native_type == Link::NATIVE_TYPE_COFFEE

      redirect_to custom_domain_coffee_url(host: @url_redirect.seller.subdomain_with_protocol, purchase_email: params[:purchase_email]), allow_other_host: true
    end

    def register_that_user_has_downloaded_product
      return if @url_redirect.nil?
      return if download_page_polling_request?

      @url_redirect.increment!(:uses, 1)
      @url_redirect.mark_as_seen
      set_confirmed_redirect_cookie
    end

    def mark_rental_as_viewed
      @url_redirect.mark_rental_as_viewed!
    end

    def fetch_url_redirect
      @url_redirect = UrlRedirect.find_by(token: params[:id])
      return e404 if @url_redirect.nil?

      # 404 if the installment had some files when this url redirect was created but now it does not (i.e. if the installment was deleted, or the creator removed the files).
      return unless @url_redirect.installment.present?
      return e404 if @url_redirect.installment.deleted?
      return if @url_redirect.referenced_link&.is_recurring_billing
      return e404 if @url_redirect.with_product_files.nil?

      has_files = @url_redirect.with_product_files.has_files?
      can_view_product_download_page_without_files =
        @url_redirect.installment.product_or_variant_type? &&
          @url_redirect.purchase_id.present?
      e404 if !has_files && !can_view_product_download_page_without_files
    end

    def check_permissions
      fetch_url_redirect

      purchase = @url_redirect.purchase

      return e404 if purchase && (purchase.stripe_refunded || (purchase.chargeback_date.present? && !purchase.chargeback_reversed))
      return redirect_to url_redirect_check_purchaser_path(@url_redirect.token, next: request.path) if purchase && user_signed_in? && purchase.purchaser.present? && logged_in_user != purchase.purchaser && !logged_in_user.is_team_member?

      return redirect_to url_redirect_rental_expired_page_path(@url_redirect.token) if @url_redirect.rental_expired?

      return redirect_to url_redirect_expired_page_path(@url_redirect.token) if purchase && purchase.is_access_revoked

      if purchase&.subscription && !purchase.subscription.grant_access_to_product?
        return redirect_to url_redirect_membership_inactive_page_path(@url_redirect.token)
      end

      if params[:access_token].present? && params[:mobile_token] == Api::Mobile::BaseController::MOBILE_TOKEN
        doorkeeper_authorize! :mobile_api
        if current_api_user.present?
          sign_in current_api_user
          return if purchase && purchase.purchaser && purchase.purchaser == logged_in_user
        end
      end

      if cookies.encrypted[:confirmed_redirect] == @url_redirect.token ||
         (purchase && ((purchase.purchaser && purchase.purchaser == logged_in_user) || purchase.ip_address == request.remote_ip))
        return
      end

      return if @url_redirect.imported_customer.present?
      return if !@url_redirect.has_been_seen || @url_redirect.purchase.nil?

      forwardable_query_params = { id: @url_redirect.token, destination: params[:action] }
      forwardable_query_params[:display] = params[:display] if params[:display].present?
      redirect_to confirm_page_path(forwardable_query_params)
    end

    def create_consumption_event!(event_type)
      ConsumptionEvent.create_event!(
        event_type:,
        platform: Platform::WEB,
        url_redirect_id: @url_redirect.id,
        product_file_id: @product_file&.id,
        purchase_id: @url_redirect.purchase_id,
        product_id: @url_redirect.purchase&.link_id || @url_redirect.link_id,
        folder_id: params[:folder_id],
        ip_address: request.remote_ip,
      )
    end

    def set_confirmed_redirect_cookie
      cookies.encrypted[:confirmed_redirect] = {
        value: @url_redirect.token,
        httponly: true
      }
    end

    def audio_durations_data
      @url_redirect.alive_product_files.where(filegroup: "audio").each_with_object({}) do |product_file, hash|
        hash[product_file.external_id] = product_file.content_length
      end
    end

    def latest_media_locations_data
      return {} if @url_redirect.purchase.nil? || @url_redirect.installment.present?

      product_files = @url_redirect.alive_product_files.select(:id)
      media_locations_by_file = MediaLocation.max_consumed_at_by_file(purchase_id: @url_redirect.purchase.id).index_by(&:product_file_id)

      product_files.each_with_object({}) do |product_file, hash|
        hash[product_file.external_id] = media_locations_by_file[product_file.id].as_json
      end
    end

    DOWNLOAD_PAGE_POLLING_PROPS = %w[audio_durations latest_media_locations].freeze

    def download_page_polling_request?
      return false unless request.headers["X-Inertia"] == "true" &&
        request.headers["X-Inertia-Partial-Component"] == "UrlRedirects/DownloadPage" &&
        request.headers["X-Inertia-Partial-Data"].present?

      requested = request.headers["X-Inertia-Partial-Data"].split(",")
      (requested - DOWNLOAD_PAGE_POLLING_PROPS).empty?
    end

    def requested_download_page_polling_props
      requested = request.headers["X-Inertia-Partial-Data"].split(",")
      props = {}
      props[:audio_durations] = audio_durations_data if requested.include?("audio_durations")
      props[:latest_media_locations] = latest_media_locations_data if requested.include?("latest_media_locations")
      props
    end

    def set_download_page_meta_tags
      set_favicon_meta_tags(@url_redirect.seller)
      set_meta_tag(title: @url_redirect.with_product_files.name == "Untitled" ? @url_redirect.referenced_link.name : @url_redirect.with_product_files.name)
      set_meta_tag(name: "apple-itunes-app", content: "app-id=#{IOS_APP_ID}, app-argument=#{@url_redirect.download_page_url}")
    end

    def create_download_page_view_consumption_event!
      return if download_page_polling_request?

      create_consumption_event!(ConsumptionEvent::EVENT_TYPE_VIEW)
    end

    def unavailable_page_props(reason_code)
      content_unavailability_reason_code = UrlRedirectPresenter::CONTENT_UNAVAILABILITY_REASON_CODES[reason_code]
      extra_props = common_props.merge(content_unavailability_reason_code:)
      UrlRedirectPresenter.new(url_redirect: @url_redirect, logged_in_user:).download_page_without_content_props(extra_props)
    end

    def common_props
      add_to_library_option = if @url_redirect.purchase && @url_redirect.purchase.purchaser.nil?
        logged_in_user.present? ? AddToLibraryOption::ADD_TO_LIBRARY_BUTTON : AddToLibraryOption::SIGNUP_FORM
      else
        AddToLibraryOption::NONE
      end

      {
        is_mobile_app_web_view: params[:display] == "mobile_app",
        content_unavailability_reason_code: @content_unavailability_reason_code,
        add_to_library_option:,
      }
    end
end
