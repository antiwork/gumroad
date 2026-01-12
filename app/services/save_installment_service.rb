# frozen_string_literal: true

class SaveInstallmentService
  attr_reader :seller, :params, :installment, :product, :preview_email_recipient, :error

  def initialize(seller:, params:, installment: nil, preview_email_recipient:)
    @seller = seller
    @params = params
    @installment = installment
    @preview_email_recipient = preview_email_recipient
  end

  def process
    set_product_and_enforce_ownership
    return false if error.present?

    ensure_seller_is_eligible_to_publish_or_schedule_emails
    return false if error.present?

    build_installment_if_needed

    begin
      unless installment.new_record?
        installment.assign_attributes(installment.published? ? published_installment_params : installment_attrs)
      end

      ActiveRecord::Base.transaction do
        installment.message = SaveContentUpsellsService.new(seller:, content: installment.message, old_content: installment.message_was).from_html
        save_installment

        if params[:to_be_published_at].present?
          schedule_installment
        elsif params[:publish].present?
          publish_installment
        elsif params[:send_preview_email].present?
          installment.send_preview_email(preview_email_recipient)
        end

        raise ActiveRecord::Rollback if error.present?
      end
    rescue Installment::InstallmentInvalid, Installment::PreviewEmailError => e
      @error = e.message
    rescue => e
      @error ||= e.message
      Bugsnag.notify(e)
    end

    error.nil?
  end

  private
    def save_installment
      unless installment.published?
        installment.installment_type = installment_params[:installment_type]
        installment.base_variant = installment_params[:installment_type] == Installment::VARIANT_TYPE ? BaseVariant.find_by_external_id(params[:variant_external_id]) : nil
        installment.link = product_or_variant_type? ? product : nil
        installment.seller = seller
      end
      if (installment.published? || installment.add_and_validate_filters(installment_attrs, seller)) && installment.save
        SaveFilesService.perform(installment, product_files_params)
        update_profile_posts_sections!
      else
        @error = installment.errors.full_messages.first
      end
    end

    def update_profile_posts_sections!
      seller.seller_profile_posts_sections.each do |section|
        shown_posts = Set.new(section.shown_posts)
        if section.external_id.in?(installment_params[:shown_in_profile_sections])
          shown_posts.add(installment.id)
        else
          shown_posts.delete(installment.id)
        end
        section.update!(shown_posts: shown_posts.to_a)
      end
    end

    def schedule_installment
      @error = "You have to confirm your email address before you can do that." unless seller.confirmed?
      return if error.present?

      timezone = ActiveSupport::TimeZone[seller.timezone]
      to_be_published_at = timezone.parse(params[:to_be_published_at])
      installment_rule = installment.installment_rule || installment.build_installment_rule
      installment_rule.to_be_published_at = to_be_published_at
      installment.ready_to_publish = true

      if installment_rule.save && installment.save
        PublishScheduledPostJob.perform_at(to_be_published_at, installment.id, installment_rule.version)
      else
        @error = installment_rule.errors.full_messages.first
      end
    end

    def publish_installment
      return if error.present?

      installment.publish!
      installment.installment_rule&.mark_deleted!
      if installment.can_be_blasted?
        blast_id = PostEmailBlast.create!(post: installment, requested_at: Time.current).id
        SendPostBlastEmailsJob.perform_async(blast_id)
      end
    end

    def set_product_and_enforce_ownership
      return unless product_or_variant_type?

      @product = installment_params[:link_id].present? ? Link.fetch(installment_params[:link_id], user: seller) : nil
      @error = "Product not found" unless product.present?
    end

    def ensure_seller_is_eligible_to_publish_or_schedule_emails
      if (params[:to_be_published_at].present? || params[:publish].present?) && installment_params[:send_emails] && !seller.eligible_to_send_emails?
        @error = "You are not eligible to publish or schedule emails. Please ensure you have made at least $#{Installment::MINIMUM_SALES_CENTS_VALUE / 100} in sales and received a payout."
      end
    end

    def build_installment_if_needed
      return if installment.present?

      @installment = product_or_variant_type? ? product.installments.build(installment_attrs) : seller.installments.build(installment_attrs)
    end

    def product_or_variant_type?
      [Installment::PRODUCT_TYPE, Installment::VARIANT_TYPE].include?(installment_params[:installment_type])
    end

    def installment_params
      params.require(:installment).permit(:name, :message, :installment_type, :link_id,
                                          :paid_more_than_cents, :paid_less_than_cents, :created_after, :created_before,
                                          :bought_from, :shown_on_profile, :send_emails, :allow_comments,
                                          bought_products: [], bought_variants: [], affiliate_products: [],
                                          not_bought_products: [], not_bought_variants: [], shown_in_profile_sections: [])
    end

    def installment_attrs
      installment_params.except(:shown_in_profile_sections)
    end

    def published_installment_params
      allowed_params = [:name, :message, :shown_on_profile, :allow_comments]
      allowed_params << :send_emails unless installment.has_been_blasted?
      published_at = params[:installment][:published_at]
      allowed_params << :published_at if published_at.present? && installment.published_at.to_date.to_s != DateTime.parse(published_at).to_date.to_s

      params.require(:installment).permit(allowed_params)
    end

    def product_files_params
      params.require(:installment).permit(files: [:external_id, :position, :url, :stream_only, subtitle_files: [:url, :language]]) || {}
    end
end
