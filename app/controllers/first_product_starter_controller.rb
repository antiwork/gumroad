# frozen_string_literal: true

class FirstProductStarterController < ApplicationController
  THROTTLE_LIMIT_PER_HOUR = 2
  THROTTLE_LIMIT_PER_IP_PER_HOUR = 30
  THROTTLE_PERIOD = 1.hour

  before_action :authenticate_user!
  before_action -> { authorize :first_product_starter, :options? }, only: :options
  before_action -> { authorize :first_product_starter, :draft? }, only: :draft
  after_action :verify_authorized

  def options
    textarea = params[:textarea_answer].to_s
    user_key = RedisKey.ai_request_throttle(current_seller.id)
    ip_key = "#{RedisKey.ai_request_throttle('ip')}:#{request.remote_ip}"
    wants_ai = textarea.strip.present?

    capped = wants_ai && !atomic_reserve(user_key, THROTTLE_LIMIT_PER_HOUR, ip_key, THROTTLE_LIMIT_PER_IP_PER_HOUR)

    service = Ai::FirstProductStarterService.new(seller: current_seller)
    result = if !wants_ai || capped
      service.template_options
    else
      service.generate_options(textarea_answer: textarea)
    end

    render json: result.merge(capped: capped)
  rescue Ai::FirstProductStarterService::MaxRetriesExceededError, Faraday::UnauthorizedError, Faraday::ClientError => e
    Rails.logger.error("[FirstProductStarter] options failed: #{e.class}: #{e.message} (seller_id=#{current_seller.id})")
    ErrorNotifier.notify(e)
    render json: { error: "couldn't_generate" }, status: :service_unavailable
  end

  def draft
    option = params.require(:option).permit(
      :name, :description, :native_type,
      :price_range, :price_currency_type,
      :is_recurring_billing, :subscription_duration
    )

    sanitized_description = ActionController::Base.helpers.sanitize(
      option[:description].to_s,
      tags: %w[p ul ol li strong em h3],
      attributes: []
    )

    @product = current_seller.links.build(
      name: option[:name],
      description: sanitized_description,
      native_type: option[:native_type],
      price_currency_type: option[:price_currency_type] || "usd",
      is_recurring_billing: option[:native_type] == "membership"
    )
    @product.price_range = option[:price_range]
    @product.subscription_duration = option[:subscription_duration] if option[:native_type] == "membership"
    @product.draft = true
    @product.purchase_disabled_at = Time.current
    @product.display_product_reviews = true
    @product.is_tiered_membership = @product.is_recurring_billing
    @product.should_show_all_posts = @product.is_tiered_membership
    @product.set_template_properties_if_needed
    @product.taxonomy = Taxonomy.find_by(slug: "other")

    begin
      @product.save!
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid
      return render json: { error: @product.errors.to_hash.transform_values(&:to_sentence).first }, status: :unprocessable_entity
    end

    create_user_event("add_product")
    create_user_event(Event::NAME_FIRST_PRODUCT_STARTER_DRAFTED)

    render json: { redirect_url: edit_link_path(@product) }
  end

  private
    def atomic_reserve(user_key, user_limit, ip_key, ip_limit)
      user_count = $redis.incr(user_key)
      ensure_expiry(user_key)
      if user_count > user_limit
        $redis.decr(user_key)
        return false
      end

      ip_count = $redis.incr(ip_key)
      ensure_expiry(ip_key)
      if ip_count > ip_limit
        $redis.decr(user_key)
        $redis.decr(ip_key)
        return false
      end

      true
    end

    def ensure_expiry(key)
      $redis.expire(key, THROTTLE_PERIOD.to_i) if $redis.ttl(key) < 0
    end
end
