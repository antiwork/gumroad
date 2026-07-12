# frozen_string_literal: true

# TEMP (revert only AFTER QA sign-off, before merge): preview-app QA harness for the
# India e-mandate work on PR #5795. Preview pods have no console access, so this adds a
# small JSON surface for exercising the renewal paths end-to-end, plus a capture hook so
# ErrorNotifier reports are observable without Sentry access.
#
# Every entry point is gated on the Stripe TEST key, so none of this can ever activate
# in production (which runs live keys).

if Rails.env.staging? || Rails.env.development?
  # Capture ErrorNotifier calls into Redis so QA can assert the new mandate telemetry fired.
  module QaErrorNotifierCapture
    def notify(exception_or_message, **context, &block)
      if Stripe.api_key.to_s.start_with?("sk_test_")
        begin
          redis = Redis::Namespace.new(:qa_india_mandate, redis: $redis)
          redis.lpush("notifications", {
            message: exception_or_message.to_s,
            context: context.transform_values(&:to_s),
            at: Time.current.iso8601
          }.to_json)
          redis.ltrim("notifications", 0, 99)
        rescue => e
          Rails.logger.error("QA notifier capture failed: #{e.message}")
        end
      end
      super
    end
  end
  # App constants are not autoloadable at initializer time (zeitwerk); defer the
  # prepend until the app's code is ready. to_prepare re-runs on reload, but
  # prepending an already-prepended module is a no-op, so this stays idempotent.
  Rails.application.config.to_prepare do
    ErrorNotifier.singleton_class.prepend(QaErrorNotifierCapture)
  end

  # JSON endpoints under /qa/india_mandate/* for driving renewal scenarios.
  class QaIndiaMandateMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      req = Rack::Request.new(env)
      return @app.call(env) unless req.path.start_with?("/qa/india_mandate/")
      return json(403, error: "test mode only") unless Stripe.api_key.to_s.start_with?("sk_test_")

      case req.path
      when "/qa/india_mandate/notifications"
        redis = Redis::Namespace.new(:qa_india_mandate, redis: $redis)
        if req.params["clear"]
          redis.del("notifications")
          json(200, cleared: true)
        else
          json(200, notifications: redis.lrange("notifications", 0, 99).map { |n| JSON.parse(n) })
        end
      when "/qa/india_mandate/subscription"
        sub = find_subscription(req.params)
        return json(404, error: "subscription not found") unless sub
        json(200, subscription_report(sub))
      when "/qa/india_mandate/force_renewal"
        sub = find_subscription(req.params)
        return json(404, error: "subscription not found") unless sub
        last_successful = sub.purchases.successful.last
        last_successful&.update_columns(created_at: 32.days.ago)
        RecurringChargeWorker.new.perform(sub.id)
        json(200, subscription_report(sub.reload))
      when "/qa/india_mandate/blank_mandate"
        sub = find_subscription(req.params)
        return json(404, error: "subscription not found") unless sub
        sub.credit_card.update!(json_data: {})
        json(200, credit_card_json_data: sub.credit_card.reload.json_data)
      else
        json(404, error: "unknown qa endpoint")
      end
    rescue => e
      json(500, error: e.class.name, message: e.message, backtrace: e.backtrace.first(5))
    end

    private
      def find_subscription(params)
        if params["subscription"].present?
          Subscription.find_by_external_id(params["subscription"])
        elsif params["email"].present?
          user = User.find_by(email: params["email"])
          user && Subscription.where(user_id: user.id).last
        end
      end

      def subscription_report(sub)
        {
          subscription: sub.external_id,
          alive: sub.alive?,
          credit_card: sub.credit_card && {
            card_country: sub.credit_card.card_country,
            requires_mandate: sub.credit_card.requires_mandate?,
            json_data: sub.credit_card.json_data
          },
          stripe_mandate: resolve_stripe_mandate(sub),
          purchases: sub.purchases.order(:id).map do |p|
            {
              external_id: p.external_id,
              state: p.purchase_state,
              error_code: p.error_code,
              stripe_error_code: p.stripe_error_code,
              is_original: p.is_original_subscription_purchase?,
              created_at: p.created_at.iso8601,
              stripe_transaction_id: p.stripe_transaction_id,
              charge_mandate: charge_mandate_for(p)
            }
          end
        }
      end

      # What get_mandate_id_from_chargeable would resolve for this card right now.
      def resolve_stripe_mandate(sub)
        cc = sub.credit_card
        return nil unless cc
        if cc.stripe_setup_intent_id
          { source: "setup_intent", id: cc.stripe_setup_intent_id,
            mandate: Stripe::SetupIntent.retrieve(cc.stripe_setup_intent_id).mandate }
        elsif cc.stripe_payment_intent_id
          pi = Stripe::PaymentIntent.retrieve(cc.stripe_payment_intent_id)
          ch = pi.latest_charge && Stripe::Charge.retrieve(pi.latest_charge)
          { source: "payment_intent", id: cc.stripe_payment_intent_id,
            mandate: ch&.payment_method_details&.card&.mandate }
        else
          { source: "none", mandate: nil }
        end
      rescue Stripe::StripeError => e
        { error: e.message }
      end

      # The mandate Stripe attached to this purchase's own charge (renewal evidence).
      def charge_mandate_for(purchase)
        return nil if purchase.stripe_transaction_id.blank?
        ch = Stripe::Charge.retrieve(purchase.stripe_transaction_id)
        ch.payment_method_details&.card&.mandate
      rescue Stripe::StripeError => e
        "error: #{e.message}"
      end

      def json(status, payload)
        [status, { "Content-Type" => "application/json" }, [payload.to_json]]
      end
  end

  Rails.application.config.middleware.insert_before(0, QaIndiaMandateMiddleware)
end
