# frozen_string_literal: true

class UrlRedirectPresenter
  include Rails.application.routes.url_helpers
  include ProductsHelper
  include ActionView::Helpers::TextHelper

  CONTENT_UNAVAILABILITY_REASON_CODES = {
    inactive_membership: "inactive_membership",
    rental_expired: "rental_expired",
    access_expired: "access_expired",
    email_confirmation_required: "email_confirmation_required",
  }.freeze

  attr_reader :url_redirect, :logged_in_user, :product, :purchase, :installment

  def initialize(url_redirect:, logged_in_user: nil)
    @url_redirect = url_redirect
    @logged_in_user = logged_in_user
    @product = url_redirect.referenced_link
    @purchase = url_redirect.purchase
    @installment = url_redirect.installment
  end

  def download_attributes
    files = url_redirect.alive_product_files.includes(:alive_subtitle_files).with_attached_thumbnail.in_order
    folder_ids_with_files = files.map(&:folder_id).compact
    product_folders = url_redirect.referenced_link&.product_folders&.where(id: folder_ids_with_files)&.in_order || []
    commission = purchase&.commission

    folders = product_folders.map do |folder|
      {
        type: "folder",
        id: folder.external_id,
        name: folder.name,
        children: files.filter_map { |file| map_file(file) if file.folder_id === folder.id }
      }
    end

    {
      content_items: (folders || []) + files.filter_map { |file| map_file(file) if !file.external_folder_id } + (commission&.is_completed? ? commission.files.map { |file| map_commission_file(file) } : [])
    }
  end

  def download_page_with_content_props(extra_props = {})
    {
      content: content_props,
      product_has_third_party_analytics: purchase&.link&.has_third_party_analytics?("receipt"),
    }.merge(download_page_layout_props).merge(extra_props)
  end

  def download_page_without_content_props(extra_props = {})
    download_page_layout_props(email_confirmation_required: extra_props[:content_unavailability_reason_code] == CONTENT_UNAVAILABILITY_REASON_CODES[:email_confirmation_required]).merge(extra_props)
  end

  private
    def download_page_layout_props(email_confirmation_required: false)
      review = purchase&.original_product_review
      call = purchase&.call

      {
        terms_page_url: HomePageLinkService.terms,
        token: url_redirect.token,
        redirect_id: url_redirect.external_id,
        creator:,
        installment: url_redirect.with_product_files.is_a?(Installment) ? {
          name: installment.name,
        } : nil,
        purchase: purchase.present? ? {
          id: purchase.external_id,
          bundle_purchase_id: purchase.is_bundle_product_purchase? ? purchase.bundle_purchase.external_id : nil,
          email: email_confirmation_required ? nil : purchase.email,
          email_digest: purchase.email_digest,
          created_at: purchase.created_at,
          is_archived: purchase.is_archived,
          product_permalink: purchase.link&.unique_permalink,
          product_id: purchase.link&.external_id,
          product_name: purchase.link&.name,
          variant_id: url_redirect.with_product_files&.is_a?(BaseVariant) ? url_redirect.with_product_files.external_id : nil,
          variant_name: purchase.variant_names&.join(", "),
          product_long_url: purchase.link&.long_url,
          allows_review: purchase.allows_review?,
          disable_reviews_after_year: purchase.seller.disable_reviews_after_year?,
          review: review.present? ? ProductReviewPresenter.new(review).review_form_props : nil,
          membership: purchase.subscription.present? ? {
            has_active_subscription: purchase.has_active_subscription?,
            subscription_id: purchase.subscription.external_id,
            is_subscription_ended: purchase.subscription.ended?,
            is_installment_plan_completed: purchase.subscription.is_installment_plan? && purchase.subscription.charges_completed?,
            is_subscription_cancelled_or_failed: purchase.subscription.cancelled_or_failed?,
            is_alive_or_restartable: purchase.subscription.alive_or_restartable?,
            in_free_trial: purchase.subscription.in_free_trial?,
            is_installment_plan: purchase.subscription.is_installment_plan,
          } : nil,
          purchase_custom_fields: purchase.purchase_custom_fields.is_post_purchase.with_attached_files.where.not(custom_field_id: nil).map do |purchase_custom_field|
            field_data = {
              custom_field_id: ObfuscateIds.encrypt(purchase_custom_field.custom_field_id),
              type: CustomField::FIELD_TYPE_TO_NODE_TYPE_MAPPING[purchase_custom_field.field_type],
            }

            if purchase_custom_field.field_type == CustomField::TYPE_FILE
              field_data[:files] = purchase_custom_field.files.map do |file|
                {
                  name: File.basename(file.filename.to_s, ".*"),
                  size: file.byte_size,
                  extension: File.extname(file.filename.to_s).delete(".").upcase,
                }
              end
            else
              field_data[:value] = purchase_custom_field.value
            end
            field_data
          end,
          call: call.present? ? {
            start_time: call.start_time,
            end_time: call.end_time,
            url: call.call_url.presence,
          } : nil,
        } : nil,
      }
    end

    def content_props
      product_files = url_redirect.alive_product_files.in_order
      rich_content_pages = url_redirect.rich_content_json.presence

      {
        license:,
        content_items: download_attributes[:content_items],
        rich_content_pages:,
        posts: posts(rich_content_pages),
        video_transcoding_info:,
        custom_receipt: nil,
        discord: purchase.present? && DiscordIntegration.is_enabled_for(purchase) ? {
          connected: DiscordIntegration.discord_user_id_for(purchase).present?
        } : nil,
        community_chat_url:,
        ios_app_url: IOS_APP_STORE_URL,
        android_app_url: ANDROID_APP_STORE_URL,
        download_all_button: product_files.any? && url_redirect.with_product_files&.is_a?(Installment) && url_redirect.with_product_files&.is_downloadable? && url_redirect.entity_archive ? {
          files: JSON.parse(url_redirect.product_files_hash),
        } : nil,
      }
    end

    def posts(rich_content_pages)
      return [] if rich_content_pages.present? && !url_redirect.has_embedded_posts?

      purchase_ids = if purchase && product
        # If the user has bought this product before/after this specific purchase, show those posts too.
        product.sales.for_displaying_installments(email: purchase.email).ids
      elsif purchase
        [purchase.id]
      end
      purchases = Purchase.where(id: purchase_ids)
      Purchase.product_installments(purchase_ids:).map do |post|
        post_purchase = purchases.find { |record| record.link_id == post.link_id } || purchase
        return unless post_purchase.present?

        seller_domain = if post.user.custom_domain&.active?
          post.user.custom_domain.domain
        else
          post.user.subdomain
        end
        view_url_payload = {
          username: post.user.username.presence || post.user.external_id,
          slug: post.slug,
          purchase_id: post_purchase.external_id,
          host: seller_domain,
          protocol: PROTOCOL
        }
        view_url = if seller_domain
          custom_domain_view_post_url(view_url_payload)
        else
          view_url_payload[:host] = UrlService.domain_with_protocol
          view_post_url(view_url_payload)
        end

        {
          id: post.external_id,
          name: post.displayed_name,
          action_at: post.action_at_for_purchases(purchase_ids),
          view_url:
        }
      end.compact
    end

    def license
      license_key = purchase&.license_key || url_redirect.imported_customer&.license_key
      return unless license_key

      {
        license_key:,
        is_multiseat_license: purchase&.is_multiseat_license,
        seats: purchase&.quantity
      }
    end

    def map_file(file)
      {
        type: "file",
        file_name: file.name_displayable,
        description: file.description,
        extension: file.display_extension,
        file_size: file.size,
        pagelength: (file.epub? ? nil : file.pagelength),
        duration: file.duration,
        id: file.external_id,
        download_url: url_redirect.is_file_downloadable?(file) ? url_redirect_download_product_files_path(url_redirect.token, { product_file_ids: [file.external_id] }) : nil,
        stream_url: file.streamable? ? url_redirect_stream_page_for_product_file_path(url_redirect.token, file.external_id) : nil,
        kindle_data: file.can_send_to_kindle? ?
                       { email: logged_in_user&.kindle_email, icon_url: ActionController::Base.helpers.asset_path("white-15.png") } :
                       nil,
        latest_media_location: media_locations_by_file[file.id].as_json,
        content_length: file.content_length,
        isbn: file.isbn,
        read_url: file.readable? ? (
          file.is_a?(Link) ? url_redirect_read_url(url_redirect.token) : file.is_a?(ProductFile) ? url_redirect_read_for_product_file_path(url_redirect.token, file.external_id) : nil
        ) : nil,
        external_link_url: file.external_link? ? file.url : nil,
        subtitle_files: file.alive_subtitle_files.map do |subtitle_file|
          {
            url: subtitle_file.url,
            file_name: subtitle_file.s3_display_name,
            extension: subtitle_file.s3_display_extension,
            language: subtitle_file.language,
            file_size: subtitle_file.size,
            download_url: url_redirect_download_subtitle_file_path(url_redirect.token, file.external_id, subtitle_file.external_id),
            signed_url: file.signed_download_url_for_s3_key_and_filename(subtitle_file.s3_key, subtitle_file.s3_filename, is_video: true)
          }
        end,
        pdf_stamp_enabled: file.pdf_stamp_enabled?,
        processing: file.pdf_stamp_enabled? && url_redirect.alive_stamped_pdfs.find_by(product_file_id: file.id).blank?,
        thumbnail_url: file.thumbnail_url
      }
    end

    def video_transcoding_info
      return unless url_redirect.rich_content_json.present?
      return unless url_redirect.alive_product_files.any?(&:streamable?)
      return unless logged_in_user == url_redirect.seller && !url_redirect.with_product_files.has_been_transcoded?

      { transcode_on_first_sale: product&.transcode_videos_on_purchase.present? }
    end

    def creator
      user = product&.user || installment&.seller
      user&.name || user&.username ? {
        name: user.name.presence || user.username,
        profile_url: user.profile_url(recommended_by: "library"),
        avatar_url: user.avatar_url
      } : nil
    end

    def media_locations_by_file
      @_media_locations_by_file ||= purchase.present? ? MediaLocation.max_consumed_at_by_file(purchase_id: purchase.id).index_by(&:product_file_id) : {}
    end

    def map_commission_file(file)
      {
        type: "file",
        file_name: File.basename(file.filename.to_s, ".*"),
        description: nil,
        extension: File.extname(file.filename.to_s).delete(".").upcase,
        file_size: file.byte_size,
        pagelength: nil,
        duration: nil,
        id: file.signed_id,
        download_url: file.blob.url,
        stream_url: nil,
        kindle_data: nil,
        latest_media_location: nil,
        content_length: nil,
        read_url: nil,
        external_link_url: nil,
        subtitle_files: [],
        pdf_stamp_enabled: false,
        processing: false,
        thumbnail_url: nil,
      }
    end

    def community_chat_url
      return unless purchase.present? && Feature.active?(:communities, purchase.seller) && product.community_chat_enabled? && product.active_community.present?

      path = community_path(purchase.seller.external_id, product.active_community.external_id)

      return signup_path(email: purchase.email, next: path) if purchase.purchaser_id.blank?

      logged_in_user.present? ? path : login_path(email: purchase.email, next: path)
    end
end
