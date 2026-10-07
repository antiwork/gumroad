# frozen_string_literal: true

# Answers a PayPal Connect dispute on the seller's behalf with the delivery record Gumroad
# holds and the seller cannot see: when the buyer opened the download page and downloaded
# each disputed item.
#
# PayPal decides what we may do on a case. The job reads the live dispute first and only
# writes when PayPal lists `provide_supporting_info` for our partner credential; on a case
# waiting for a seller response (`accept_claim`/`make_offer`/`escalate` only) it does nothing,
# and the seller keeps handling that case in their PayPal account.
#
# PayPal accepts one note per call and the note cannot be withdrawn, so a Redis claim keeps
# a re-delivered webhook or a Sidekiq retry from posting the same note twice.
class SubmitPaypalDisputeEvidenceJob
  include Sidekiq::Job
  # No until_executed lock: the same dispute is deliberately enqueued twice (10 minutes and 7 days
  # out), and the Redis claim below is what keeps it to one submission.
  sidekiq_options retry: 3, queue: :default

  FEATURE_FLAG = :submit_paypal_dispute_evidence
  ACTION_REL = "provide_supporting_info"
  CLAIM_TTL = 120.days.to_i
  MAX_EVENTS_PER_PURCHASE = 10

  def self.claim_key(dispute_id) = "paypal_dispute_evidence_submitted:#{dispute_id}"

  def perform(dispute_id)
    return unless Feature.active?(FEATURE_FLAG)

    dispute = Dispute.find(dispute_id)
    return unless dispute.charge_processor_id == PaypalChargeProcessor.charge_processor_id
    return if dispute.charge_processor_dispute_id.blank?
    return if dispute.won_at.present? || dispute.lost_at.present?

    purchases = dispute.purchases.compact
    merchant_account = purchases.first&.merchant_account
    return if merchant_account&.charge_processor_merchant_id.blank?

    notes = self.class.evidence_notes(purchases)
    return if notes.nil?

    api = PaypalRestApi.new
    live = api.fetch_dispute(dispute_id: dispute.charge_processor_dispute_id, merchant_account:)
    return Rails.logger.info("SubmitPaypalDisputeEvidenceJob: dispute #{dispute.id} read failed (#{live.status_code})") unless api.successful_response?(live)
    return unless self.class.action_offered?(live.result)

    key = self.class.claim_key(dispute.id)
    return unless $redis.set(key, Time.current.to_i, nx: true, ex: CLAIM_TTL)

    response = api.provide_dispute_supporting_info(dispute_id: dispute.charge_processor_dispute_id, merchant_account:, notes:)
    if api.successful_response?(response)
      Rails.logger.info("SubmitPaypalDisputeEvidenceJob: submitted delivery record for dispute #{dispute.id}")
    else
      # PayPal refused the note, so nothing reached the case: release the claim so a later run
      # can try again once the case accepts information.
      $redis.del(key)
      ErrorNotifier.notify("SubmitPaypalDisputeEvidenceJob: PayPal rejected supporting info for dispute #{dispute.id} (#{response.status_code})")
    end
  end

  def self.action_offered?(result)
    links = result.respond_to?(:links) ? result.links : (result.is_a?(Hash) ? result["links"] : nil)
    Array(links).any? do |link|
      rel = link.respond_to?(:rel) ? link.rel : link["rel"]
      rel == ACTION_REL
    end
  end

  # Returns nil when no disputed item was ever opened: a note that says "never downloaded"
  # would only help the buyer, so that case is left to the seller.
  def self.evidence_notes(purchases)
    lines = []
    any_access = false
    purchases.each do |purchase|
      events = ConsumptionEvent.where(purchase_id: purchase.id,
                                      event_type: [ConsumptionEvent::EVENT_TYPE_VIEW, ConsumptionEvent::EVENT_TYPE_DOWNLOAD, ConsumptionEvent::EVENT_TYPE_DOWNLOAD_ALL])
                               .order(:created_at).limit(MAX_EVENTS_PER_PURCHASE).pluck(:event_type, :created_at)
      any_access ||= events.any?
      line = "#{purchase.link.name} (Gumroad order #{purchase.external_id}, paid #{fmt(purchase.created_at)}): "
      line += events.any? ? events.map { |type, at| "#{type == ConsumptionEvent::EVENT_TYPE_VIEW ? "download page opened" : "file downloaded"} #{fmt(at)}" }.join("; ") : "no access recorded"
      lines << line
    end
    return nil unless any_access

    ["Digital product delivered instantly by Gumroad, the seller's checkout platform. Gumroad's access log for this order:",
     *lines,
     "All times UTC."].join("\n")
  end

  def self.fmt(time) = time.utc.strftime("%Y-%m-%d %H:%M:%S")
end
