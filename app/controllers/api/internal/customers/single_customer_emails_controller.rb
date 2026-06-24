# frozen_string_literal: true

require "digest"

class Api::Internal::Customers::SingleCustomerEmailsController < Api::Internal::BaseController
  REDIS_LOCK_TTL = 30.seconds
  REDIS_LOCK_WAIT_TIMEOUT = 10.seconds
  REDIS_LOCK_RETRY_INTERVAL_SECONDS = 0.05
  DELIVERY_CACHE_TTL = 8.hours
  DELIVERY_IN_PROGRESS_CACHE_TTL = 5.minutes
  DELIVERY_IN_PROGRESS_CACHE_VALUE = "in_progress"
  DELIVERY_SENT_CACHE_VALUE = "sent"
  REDIS_LOCK_RELEASE_SCRIPT = <<~LUA.squish
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  LUA

  before_action :authenticate_user!
  after_action :verify_authorized

  def create
    permitted_params = single_customer_email_params
    purchase = current_seller.sales.find_by_external_id!(permitted_params[:purchase_id])

    authorize Installment, :create?

    return render_error("Customer not found.", :not_found) unless seller_can_email_customers?
    return render_error("Customer cannot be emailed.", :unprocessable_entity) unless customer_can_receive_email?(purchase)
    return render_error("You are not eligible to send emails.", :unauthorized) unless current_seller.eligible_to_send_emails?
    return render_error("Please set a title.", :unprocessable_entity) if permitted_params[:name].blank?

    installment = find_or_create_installment(purchase, permitted_params)
    deliver_to_purchase(installment, purchase)

    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    authorize Installment, :create?
    render_error("Customer not found.", :not_found)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.first || e.message, :unprocessable_entity)
  rescue Installment::InstallmentInvalid => e
    render_error(e.message, :unprocessable_entity)
  end

  private
    def single_customer_email_params
      params.permit(:purchase_id, :name, :message, files: [:external_id, :position, :url, :stream_only, subtitle_files: [:url, :language]])
    end

    # Build the email exactly once per identical request. The key is the request's
    # content digest, not the new installment's id, so a retry reuses the existing
    # installment instead of creating a second one. Creation is deliberately kept
    # separate from delivery: keying them together would let a failed send re-run
    # creation and leave duplicate published installments behind.
    def find_or_create_installment(purchase, permitted_params)
      idempotency_key = single_customer_email_idempotency_key(purchase, permitted_params)
      installment_id = with_redis_lock("#{idempotency_key}:lock") do
        Rails.cache.fetch(idempotency_key, expires_in: 8.hours) do
          ActiveRecord::Base.transaction do
            message = SaveContentUpsellsService.new(seller: current_seller, content: permitted_params[:message], old_content: nil).from_html
            installment = current_seller.installments.build(
              name: permitted_params[:name],
              message:,
              installment_type: Installment::SELLER_TYPE,
              send_emails: true,
              shown_on_profile: false,
              allow_comments: false,
              single_recipient_email: true,
              single_recipient_purchase_id: purchase.id
            )
            installment.save!
            SaveFilesService.perform(installment, files_params(permitted_params))
            installment.publish!
            blast_timestamp = Time.current
            PostEmailBlast.create!(
              post: installment,
              requested_at: blast_timestamp,
              started_at: blast_timestamp,
              completed_at: blast_timestamp
            )
            installment.id
          end
        end
      end

      current_seller.installments.find(installment_id)
    end

    # Deliver after the installment is committed and behind its own single-customer
    # idempotency key. Do not reuse PostsController's generic resend key; sellers
    # should still be able to resend the email from the post UI after the initial
    # one-off send succeeds.
    # PostEmailApi.process hits an external provider (Resend/SendGrid), so it must
    # not run inside the creation transaction: a post-send rollback would orphan an
    # already-delivered email. Reserve the delivery cache key before the provider
    # call and release the short Redis lock before sending; otherwise a provider
    # call longer than the lock TTL could allow a retry to acquire the lock and
    # send the same email again.
    def deliver_to_purchase(installment, purchase)
      cache_key = delivery_cache_key(installment, purchase)
      return if delivery_already_sent_or_reserved!(cache_key, installment, purchase) == :sent

      provider_delivery_recorded = false
      begin
        CreatorContactingCustomersEmailInfo.where(purchase:, installment:).destroy_all
        PostEmailApi.process(
          post: installment,
          recipients: [
            {
              email: purchase.email,
              purchase:,
              url_redirect: installment.delivery_url_redirect_for(purchase),
              subscription: purchase.subscription,
            }.compact_blank
          ],
          after_provider_delivery: lambda {
            provider_delivery_recorded = mark_delivery_sent(cache_key)
          }
        )
        mark_delivery_sent(cache_key) unless provider_delivery_recorded
      rescue StandardError
        if delivery_sent_cache?(cache_key)
          ensure_delivery_recorded!(installment, purchase)
        elsif !delivery_recorded?(installment, purchase)
          Rails.cache.delete(cache_key)
        end
        raise
      end
    end

    def delivery_already_sent_or_reserved!(cache_key, installment, purchase)
      with_redis_lock("#{cache_key}:lock") do
        cache_value = Rails.cache.read(cache_key)
        if [DELIVERY_SENT_CACHE_VALUE, true].include?(cache_value)
          ensure_delivery_recorded!(installment, purchase)
          :sent
        elsif delivery_recorded?(installment, purchase)
          mark_delivery_sent(cache_key)
          :sent
        elsif cache_value == DELIVERY_IN_PROGRESS_CACHE_VALUE
          raise Installment::InstallmentInvalid, "This email is already being sent. Please wait a few minutes before trying again."
        else
          Rails.cache.write(cache_key, DELIVERY_IN_PROGRESS_CACHE_VALUE, expires_in: DELIVERY_IN_PROGRESS_CACHE_TTL)
          :reserved
        end
      end
    end

    def mark_delivery_sent(cache_key)
      Rails.cache.write(cache_key, DELIVERY_SENT_CACHE_VALUE, expires_in: DELIVERY_CACHE_TTL)
      true
    rescue StandardError => e
      Rails.logger.warn("Failed to write single-customer email delivery cache #{cache_key}: #{e.class}: #{e.message}")
      false
    end

    def delivery_sent_cache?(cache_key)
      Rails.cache.read(cache_key) == DELIVERY_SENT_CACHE_VALUE
    rescue StandardError
      false
    end

    def delivery_recorded?(installment, purchase)
      CreatorContactingCustomersEmailInfo.exists?(purchase:, installment:)
    end

    def ensure_delivery_recorded!(installment, purchase)
      CreatorContactingCustomersEmailInfo.where(purchase:, installment:).first_or_create!(
        email_name: EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD,
        state: "sent",
        sent_at: Time.current
      )
    end

    def delivery_cache_key(installment, purchase)
      "single_customer_email_delivery:#{installment.id}:#{purchase.id}"
    end

    def with_redis_lock(lock_key)
      token = SecureRandom.uuid
      lock_acquired = false
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REDIS_LOCK_WAIT_TIMEOUT

      until $redis.set(lock_key, token, ex: REDIS_LOCK_TTL.to_i, nx: true)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise Installment::InstallmentInvalid, "Please wait a few seconds and try sending again."
        end

        sleep REDIS_LOCK_RETRY_INTERVAL_SECONDS
      end

      lock_acquired = true
      yield
    ensure
      $redis.eval(REDIS_LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: [token]) if lock_acquired
    end

    def files_params(permitted_params)
      { files: permitted_params[:files] || [] }.with_indifferent_access
    end

    def single_customer_email_idempotency_key(purchase, permitted_params)
      content_digest = Digest::SHA256.hexdigest(
        [
          permitted_params[:name].to_s,
          permitted_params[:message].to_s,
          canonical_idempotency_value(files_params(permitted_params)[:files]).to_json,
        ].join("\x00")
      )

      "single_customer_email:#{current_seller.id}:#{purchase.id}:#{content_digest}"
    end

    def canonical_idempotency_value(value)
      case value
      when ActionController::Parameters
        canonical_idempotency_value(value.to_h)
      when Hash
        value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |inner_value| canonical_idempotency_value(inner_value) }
      when Array
        value.map { |inner_value| canonical_idempotency_value(inner_value) }
      else
        value
      end
    end

    def seller_can_email_customers?
      UserPresenter.new(user: current_seller).audience_types.include?(:customers)
    end

    def customer_can_receive_email?(purchase)
      purchase.can_contact? && EmailFormatValidator.valid?(purchase.email) && !purchase.is_gift_sender_purchase?
    end

    def render_error(message, status)
      render json: { success: false, message: }, status:
    end
end
