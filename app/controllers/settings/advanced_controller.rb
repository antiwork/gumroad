# frozen_string_literal: true

class Settings::AdvancedController < Settings::BaseController
  before_action :authorize

  def show
    render inertia: "Settings/Advanced/Show", props: settings_presenter.advanced_props
  end

  def update
    begin
      BlockedCustomerObject.transaction do
        block_customer_emails
      end

      if @invalid_blocked_email.present?
        return redirect_to settings_advanced_path, alert: "The email #{@invalid_blocked_email} cannot be blocked as it is invalid."
      end
    rescue => e
      Bugsnag.notify(e)
      logger.error "Couldn't block customer emails: #{e.message}"
      return redirect_to settings_advanced_path, alert: "Sorry, something went wrong. Please try again."
    end

    begin
      current_seller.with_lock { current_seller.update(advanced_params) }
    rescue => e
      Bugsnag.notify(e)
      return redirect_to settings_advanced_path, alert: "Something broke. We're looking into what happened. Sorry about this!"
    end

    if params[:domain].present?
      custom_domain = current_seller.custom_domain || current_seller.build_custom_domain
      custom_domain.domain = params[:domain]
      custom_domain.verify(allow_incrementing_failed_verification_attempts_count: false)
      begin
        error_message = custom_domain.errors.full_messages.to_sentence unless custom_domain.save
      rescue ActiveRecord::RecordNotUnique
        error_message = "The custom domain is already in use."
      end
      if error_message
        return redirect_to settings_advanced_path, alert: error_message
      end
    elsif params[:domain] == "" && current_seller.custom_domain.present?
      current_seller.custom_domain.mark_deleted!
    end

    if current_seller.save
      redirect_to settings_advanced_path, status: :see_other, notice: "Your account has been updated!"
    else
      redirect_to settings_advanced_path, alert: current_seller.errors.full_messages.to_sentence
    end
  end

  private
    def advanced_params
      params.require(:user).permit(:notification_endpoint)
    end

    def block_customer_emails
      set_emails_to_block
      set_invalid_blocked_email_if_exists
      return if @invalid_blocked_email.present?

      if @emails_to_block.any?
        previously_blocked_emails = current_seller.blocked_customer_objects.active.email.pluck(:object_value)
        emails_to_unblock = previously_blocked_emails - @emails_to_block
        current_seller.blocked_customer_objects.active.email.where(object_value: emails_to_unblock).find_each(&:unblock!)
        @emails_to_block.each { |email| BlockedCustomerObject.block_email!(email:, seller_id: current_seller.id) }
      else
        current_seller.blocked_customer_objects.active.find_each(&:unblock!)
      end
    end

    def set_emails_to_block
      @emails_to_block = (params[:blocked_customer_emails].presence || "").split(/[\r\n]+/)
    end

    def set_invalid_blocked_email_if_exists
      @invalid_blocked_email = @emails_to_block.detect { |email| !EmailFormatValidator.valid?(email) }
    end

    def authorize
      super([:settings, :advanced, current_seller])
    end
end
