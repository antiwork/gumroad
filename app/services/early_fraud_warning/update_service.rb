# frozen_string_literal: true

class EarlyFraudWarning::UpdateService
  class AlreadyResolvedError < StandardError; end

  def initialize(record)
    @record = record
    @chargeable = record.chargeable
  end

  def perform!
    # We want to preserve the record in its original state just before it was processed by us.
    # In some cases (e.g. after refunding for fraud), there will be a webhook request sent, that would affect our
    # reporting data, so we don't want to process those.
    # Basically, once an EFW is resolved, it is locked, and we don't want any more updates to it.
    raise AlreadyResolvedError if record.resolved?

    efw_object = fetch_stripe_object(chargeable, record.processor_id)
    record.update!(
      purchase: (chargeable if chargeable.is_a?(Purchase)),
      charge: (chargeable if chargeable.is_a?(Charge)),
      dispute: chargeable.dispute,
      refund: chargeable.refunds.first,
      fraud_type: efw_object.fraud_type,
      actionable: efw_object.actionable,
      charge_risk_level: efw_object.charge.outcome.risk_level,
      processor_created_at: Time.zone.at(efw_object.created),
    )
  end

  private
    attr_reader :chargeable, :record

    # Retrieve the EFW object from Stripe to ensure we have the latest data
    # (we have to fetch the charge object anyway, to get the risk level)
    def fetch_stripe_object(chargeable, stripe_object_id)
      if chargeable.charged_using_stripe_connect_account?
        Stripe::Radar::EarlyFraudWarning.retrieve(
          { id: stripe_object_id, expand: %w(charge) },
          { stripe_account: chargeable.merchant_account.charge_processor_merchant_id }
        )
      else
        Stripe::Radar::EarlyFraudWarning.retrieve({ id: stripe_object_id, expand: %w(charge) })
      end
    end
end
