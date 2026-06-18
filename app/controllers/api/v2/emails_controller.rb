# frozen_string_literal: true

class Api::V2::EmailsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_emails }
  before_action :fetch_installment, only: %i[show preview send_email destroy]

  RESULTS_PER_PAGE = 10
  AUDIENCE_TYPES_BY_PARAM = {
    "all" => Installment::AUDIENCE_TYPE,
    "audience" => Installment::AUDIENCE_TYPE,
    "customers" => Installment::SELLER_TYPE,
    "seller" => Installment::SELLER_TYPE,
    "followers" => Installment::FOLLOWER_TYPE,
    "follower" => Installment::FOLLOWER_TYPE,
    "product" => Installment::PRODUCT_TYPE,
  }.freeze

  def index
    installments = filter_installments_by_type(scoped_installments)
    return if performed?

    if params[:page_key].present?
      begin
        last_installment_created_at, last_installment_id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      installments = installments.where("(created_at < ?) OR (created_at = ? AND id < ?)", last_installment_created_at, last_installment_created_at, last_installment_id)
    end

    paginated_installments = installments
                             .includes(:installment_rule, :link)
                             .order(created_at: :desc, id: :desc)
                             .limit(RESULTS_PER_PAGE + 1)
                             .to_a
    has_next_page = paginated_installments.size > RESULTS_PER_PAGE
    paginated_installments = paginated_installments.first(RESULTS_PER_PAGE)
    additional_response = has_next_page ? pagination_info(paginated_installments.last) : {}

    success_with_object(:emails, paginated_installments, additional_response)
  end

  def show
    success_with_email(@installment)
  end

  def create
    installment_type = installment_type_from_audience_param
    return if performed?

    product_link_id = product_link_id_for(installment_type)
    return if performed?

    service = SaveInstallmentService.new(
      seller: current_seller,
      params: service_params_for_create(installment_type:, product_link_id:),
      installment: nil,
      preview_email_recipient: current_seller
    )

    if service.process
      success_with_email(service.installment)
    else
      render_response(false, message: service.error)
    end
  end

  def preview
    ensure_installment_seller
    @installment.send_preview_email(current_seller)
    render_response(
      true,
      email: @installment,
      preview_url: preview_url_for(@installment),
      message: "A preview has been sent to your email."
    )
  rescue Installment::PreviewEmailError => e
    render_response(false, message: e.message)
  rescue => e
    ErrorNotifier.notify(e)
    render_response(false, message: e.message)
  end

  def send_email
    return render_response(false, message: "The email has already been sent.") if @installment.has_been_blasted?
    return render_response(false, message: "The email is scheduled to be sent at its scheduled time.") if !@installment.published? && @installment.ready_to_publish?

    ensure_installment_seller
    ensure_implicit_purchase_filters
    service = SaveInstallmentService.new(
      seller: current_seller,
      params: service_params_for_publish(@installment),
      installment: @installment,
      preview_email_recipient: current_seller
    )

    if service.process
      success_with_email(service.installment)
    else
      render_response(false, message: service.error)
    end
  end

  def destroy
    if @installment.update(deleted_at: Time.current)
      success_with_email
    else
      error_with_email(@installment)
    end
  end

  private
    def current_seller
      current_resource_owner
    end

    def scoped_installments
      Installment.ordered_updates(current_seller, nil).reorder(nil)
    end

    def filter_installments_by_type(installments)
      case params[:type].presence
      when nil
        installments
      when Installment::PUBLISHED
        installments.published
      when Installment::SCHEDULED
        installments.scheduled
      when Installment::DRAFT
        installments.draft
      else
        error_400(
          "Invalid type. Valid values are: " \
          "#{[Installment::PUBLISHED, Installment::SCHEDULED, Installment::DRAFT].join(', ')}."
        )
      end
    end

    def fetch_installment
      @installment = scoped_installments.find_by_external_id(params[:id])
      error_with_email if @installment.nil?
    end

    def ensure_installment_seller
      return if @installment.seller_id.present?

      @installment.update_column(:seller_id, current_seller.id)
      @installment.seller = current_seller
    end

    def ensure_implicit_purchase_filters
      @installment.bought_products = bought_products_for_publish(@installment)
      @installment.bought_variants = bought_variants_for_publish(@installment)
    end

    def installment_type_from_audience_param
      audience = params[:audience].presence || Installment::AUDIENCE_TYPE
      AUDIENCE_TYPES_BY_PARAM[audience.to_s.downcase] ||
        installment_creation_error("Invalid audience. Valid values are: #{AUDIENCE_TYPES_BY_PARAM.keys.join(', ')}.")
    end

    def product_link_id_for(installment_type)
      return unless installment_type == Installment::PRODUCT_TYPE

      product_identifier = params[:product_id].presence || params[:link_id].presence
      if product_identifier.blank?
        return installment_creation_error("Product audience requires a product_id or link_id.")
      end

      product = current_seller.links.visible.find_by_external_id(product_identifier) ||
                current_seller.links.visible.find_by(unique_permalink: product_identifier)
      return installment_creation_error("Product not found.") unless product

      product.unique_permalink
    end

    def service_params_for_create(installment_type:, product_link_id:)
      ActionController::Parameters.new(
        installment: {
          name: params[:subject],
          message: params[:body],
          installment_type:,
          link_id: product_link_id,
          bought_products: (installment_type == Installment::PRODUCT_TYPE ? [product_link_id] : []),
          send_emails: true,
          shown_on_profile: false,
          shown_in_profile_sections: [],
        },
        publish: ("true" if publish_requested?)
      )
    end

    def service_params_for_publish(installment)
      service_params = {
        installment: installment_service_attributes(installment),
        publish: "true",
      }
      if installment.variant_type? && installment.base_variant.present?
        service_params[:variant_external_id] = installment.base_variant.external_id
      end
      ActionController::Parameters.new(service_params)
    end

    def installment_service_attributes(installment)
      {
        name: installment.name,
        message: installment.message,
        installment_type: installment.installment_type,
        link_id: installment.link&.unique_permalink,
        paid_more_than_cents: installment.paid_more_than_cents,
        paid_less_than_cents: installment.paid_less_than_cents,
        created_after: installment.created_after,
        created_before: installment.created_before,
        bought_from: installment.bought_from,
        shown_on_profile: installment.shown_on_profile?,
        send_emails: true,
        allow_comments: installment.allow_comments?,
        bought_products: bought_products_for_publish(installment),
        bought_variants: bought_variants_for_publish(installment),
        affiliate_products: installment.affiliate_products,
        not_bought_products: installment.not_bought_products,
        not_bought_variants: installment.not_bought_variants,
        shown_in_profile_sections: shown_in_profile_sections_for(installment),
        files: existing_files_for(installment),
      }
    end

    def bought_products_for_publish(installment)
      return installment.bought_products if has_purchase_filter?(installment) || !installment.product_type?

      Array(installment.link&.unique_permalink).compact
    end

    def bought_variants_for_publish(installment)
      return installment.bought_variants if has_purchase_filter?(installment) || !installment.variant_type?

      Array(installment.base_variant&.external_id).compact
    end

    def has_purchase_filter?(installment)
      installment.bought_products.present? || installment.bought_variants.present?
    end

    def existing_files_for(installment)
      installment.alive_product_files.map do |file|
        {
          external_id: file.external_id,
          url: file.url,
          position: file.position,
          stream_only: file.stream_only?,
          subtitle_files: file.alive_subtitle_files.map { |subtitle| { url: subtitle.url, language: subtitle.language } },
        }
      end
    end

    def shown_in_profile_sections_for(installment)
      current_seller.seller_profile_posts_sections.filter_map do |section|
        section.external_id if section.shown_posts.include?(installment.id)
      end
    end

    def publish_requested?
      boolean_param(:publish) || boolean_param(:draft) == false
    end

    def boolean_param(key)
      ActiveModel::Type::Boolean.new.cast(params[key])
    end

    def preview_url_for(installment)
      return installment.public_page_location if installment.published?

      edit_email_url(installment.external_id, preview_post: true, host: UrlService.domain_with_protocol)
    end

    def installment_creation_error(message)
      installment = Installment.new
      installment.errors.add(:base, message)
      error_with_creating_object(:email, installment)
      nil
    end

    def success_with_email(installment = nil)
      success_with_object(:email, installment)
    end

    def error_with_email(installment = nil)
      error_with_object(:email, installment)
    end
end
