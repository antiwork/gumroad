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
  IN_FLIGHT_CLAIM_TTL = 15.minutes.to_i
  MAX_VIEWS_PER_PURCHASE = 5
  MAX_ACCESSES_PER_PURCHASE = 20
  ACCESS_LABELS = {
    ConsumptionEvent::EVENT_TYPE_VIEW => "download page opened",
    ConsumptionEvent::EVENT_TYPE_DOWNLOAD => "file downloaded",
    ConsumptionEvent::EVENT_TYPE_DOWNLOAD_ALL => "all files downloaded",
    ConsumptionEvent::EVENT_TYPE_FOLDER_DOWNLOAD => "folder downloaded",
    ConsumptionEvent::EVENT_TYPE_READ => "document read",
    ConsumptionEvent::EVENT_TYPE_WATCH => "video watched",
    ConsumptionEvent::EVENT_TYPE_LISTEN => "audio listened to",
  }.freeze

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
    return unless $redis.set(key, Time.current.to_i, nx: true, ex: IN_FLIGHT_CLAIM_TTL)

    confirmed = false
    begin
      response = api.provide_dispute_supporting_info(dispute_id: dispute.charge_processor_dispute_id, merchant_account:, notes:)
      if api.successful_response?(response)
        confirmed = true
        $redis.expire(key, CLAIM_TTL)
        Rails.logger.info("SubmitPaypalDisputeEvidenceJob: submitted delivery record for dispute #{dispute.id}")
      else
        ErrorNotifier.notify("SubmitPaypalDisputeEvidenceJob: PayPal rejected supporting info for dispute #{dispute.id} (#{response.status_code})")
      end
    ensure
      # Only a confirmed submission keeps the claim; a rejection or an error before the note
      # reached PayPal releases it so a retry or the 7-day run can send it.
      $redis.del(key) unless confirmed
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
      accesses = access_events(access_purchases(purchase))
      any_access ||= accesses.any?
      line = "#{purchase.link.name} (Gumroad order #{purchase.external_id}, paid #{fmt(purchase.created_at)}): "
      line += accesses.any? ? accesses.join("; ") : "no access recorded"
      lines << line
    end
    return nil unless any_access

    ["Digital product delivered instantly by Gumroad, the seller's checkout platform. Gumroad's access log for this order:",
     *lines,
     "All times UTC."].join("\n")
  end

  # Access rows of a bundle are written against its member purchases, not the wrapper.
  def self.access_purchases(purchase)
    return [purchase] unless purchase.is_bundle_purchase?

    [purchase, *purchase.product_purchases]
  end

  # Downloads and reads are the proof, so page opens are capped on their own and a note that
  # drops anything says so.
  def self.access_events(purchases)
    rows = ConsumptionEvent.where(purchase_id: purchases.map(&:id), event_type: ACCESS_LABELS.keys)
                           .order(Arel.sql("COALESCE(consumed_at, created_at), id"))
                           .pluck(:event_type, :consumed_at, :created_at)
                           .map { |type, consumed_at, created_at| [type, consumed_at || created_at] }
    views, others = rows.partition { |type, _| type == ConsumptionEvent::EVENT_TYPE_VIEW }
    kept_others = others.first(MAX_ACCESSES_PER_PURCHASE)
    kept_views = views.first(MAX_VIEWS_PER_PURCHASE)
    entries = (kept_views + kept_others).sort_by { |_, at| at }.map { |type, at| "#{ACCESS_LABELS.fetch(type)} #{fmt(at)}" }
    omitted = rows.size - kept_views.size - kept_others.size
    entries << "#{omitted} more page opens or accesses not listed" if omitted.positive?
    entries
  end

  def self.fmt(time) = time.utc.strftime("%Y-%m-%d %H:%M:%S")
end
