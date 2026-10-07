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
  # Minutes, not seconds: a PayPal outage or rate-limit window outlasts Sidekiq's default backoff.
  sidekiq_retry_in { |count| 5.minutes.to_i * (count + 1) }

  FEATURE_FLAG = :submit_paypal_dispute_evidence
  ACTION_REL = "provide_supporting_info"
  CLAIM_TTL = 120.days.to_i
  IN_FLIGHT_CLAIM_TTL = 15.minutes.to_i
  MAX_VIEWS_PER_PURCHASE = 5
  MAX_ACCESSES_PER_PURCHASE = 20
  # PayPal's supporting-info schema caps `notes` at 2,000 characters; an oversized note is
  # rejected whole, so the complete note is fitted to this budget.
  MAX_NOTES_LENGTH = 2_000
  # Product names may be 255 characters; a short name leaves room for the access proof.
  MAX_NAME_LENGTH = 60
  NOTES_HEADER = "Digital product delivered instantly by Gumroad, the seller's checkout platform. Gumroad's access log for this order:"
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
    return Rails.logger.info("SubmitPaypalDisputeEvidenceJob: no note for dispute #{dispute.id} (no recorded access, or too many orders to fit)") if notes.nil?

    api = PaypalRestApi.new
    live = api.fetch_dispute(dispute_id: dispute.charge_processor_dispute_id, merchant_account:)
    unless api.successful_response?(live)
      status = live.status_code.to_i
      # A short outage or rate limit may clear within the Sidekiq retries. A missing grant will
      # not, so report it once a day per merchant account instead of on every dispute.
      raise "SubmitPaypalDisputeEvidenceJob: PayPal returned #{status} reading dispute #{dispute.id}" if self.class.transient_status?(status)

      if [401, 403].include?(status) && $redis.set("paypal_dispute_read_denied:#{merchant_account.id}", status, nx: true, ex: 1.day.to_i)
        ErrorNotifier.notify("SubmitPaypalDisputeEvidenceJob: PayPal denied reading dispute #{dispute.id} (#{status}) for merchant account #{merchant_account.id}")
      end
      return Rails.logger.info("SubmitPaypalDisputeEvidenceJob: dispute #{dispute.id} read failed (#{status})")
    end
    return unless self.class.action_offered?(live.result)
    # The claim cannot tell a lost success response from a failure, so the case itself is the
    # final check: never post a second copy of a note PayPal already holds.
    return if self.class.already_submitted?(live.result)

    key = self.class.claim_key(dispute.id)
    return unless $redis.set(key, Time.current.to_i, nx: true, ex: IN_FLIGHT_CLAIM_TTL)

    confirmed = false
    begin
      response = api.provide_dispute_supporting_info(dispute_id: dispute.charge_processor_dispute_id, merchant_account:, notes:)
      if api.successful_response?(response)
        confirmed = true
        persist_claim(key)
        Rails.logger.info("SubmitPaypalDisputeEvidenceJob: submitted delivery record for dispute #{dispute.id}")
      else
        # The claim is released below either way; a transient status also retries through Sidekiq.
        raise "SubmitPaypalDisputeEvidenceJob: PayPal returned #{response.status_code} sending supporting info for dispute #{dispute.id}" if self.class.transient_status?(response.status_code.to_i)

        ErrorNotifier.notify("SubmitPaypalDisputeEvidenceJob: PayPal rejected supporting info for dispute #{dispute.id} (#{response.status_code})")
      end
    ensure
      # Only a confirmed submission keeps the claim; a rejection or an error before the note
      # reached PayPal releases it so a retry or the 7-day run can send it.
      $redis.del(key) unless confirmed
    end
  end

  # The note is already with PayPal, so a Redis error here must not fail the job into a retry
  # that posts it again; the live-case check in `perform` still catches a repeat.
  def persist_claim(key)
    $redis.set(key, Time.current.to_i, ex: CLAIM_TTL)
  rescue Redis::BaseError => e
    ErrorNotifier.notify(e)
  end

  def self.transient_status?(status) = status >= 500 || [408, 429].include?(status)

  def self.action_offered?(result)
    links = result.respond_to?(:links) ? result.links : (result.is_a?(Hash) ? result["links"] : nil)
    Array(links).any? do |link|
      rel = link.respond_to?(:rel) ? link.rel : link["rel"]
      rel == ACTION_REL
    end
  end

  def self.already_submitted?(result)
    info = result.respond_to?(:supporting_info) ? result.supporting_info : (result.is_a?(Hash) ? result["supporting_info"] : nil)
    Array(info).any? do |entry|
      notes = entry.respond_to?(:notes) ? entry.notes : entry["notes"]
      notes.to_s.start_with?(NOTES_HEADER)
    end
  end

  # Returns nil when no disputed item was ever opened: a note that says "never downloaded"
  # would only help the buyer, so that case is left to the seller. Orders with no recorded
  # access are left out of the note rather than described as unopened.
  def self.evidence_notes(purchases)
    sections = purchases.filter_map do |purchase|
      access = access_events(access_purchases(purchase))
      next if access.first.empty?

      ["#{purchase.link.name.truncate(MAX_NAME_LENGTH)} (Gumroad order #{purchase.external_id}, paid #{fmt(purchase.created_at)}): ", access]
    end
    return nil if sections.empty?

    fit_to_budget(sections)
  end

  # Builds the note within MAX_NOTES_LENGTH. Entries are already proof-first per purchase
  # (downloads/reads before page opens), so trimming drops the tail of each purchase's list
  # in turn and says how many entries were left out. Every accessed purchase keeps its first
  # proof entry; returns nil rather than send a note that would carry no proof for one of them.
  def self.fit_to_budget(sections)
    keep = sections.map { |_, (accesses, _)| accesses.size }
    floor = Array.new(sections.size, 1)
    loop do
      note = render_note(sections, keep)
      return note if note.length <= MAX_NOTES_LENGTH

      trimmable = keep.each_index.select { |i| keep[i] > floor[i] }
      return nil if trimmable.empty?

      keep[trimmable.max_by { |i| keep[i] }] -= 1
    end
  end

  def self.render_note(sections, keep)
    lines = sections.each_with_index.map do |(prefix, (accesses, omitted)), i|
      shown = accesses.first(keep[i])
      dropped = omitted + accesses.size - shown.size
      body = shown.join("; ")
      body += "; #{dropped} more entries not listed" if dropped.positive?
      prefix + body
    end
    [NOTES_HEADER, *lines, "All times UTC."].join("\n")
  end

  # Access rows of a bundle are written against its member purchases, not the wrapper.
  def self.access_purchases(purchase)
    return [purchase] unless purchase.is_bundle_purchase?

    [purchase, *purchase.product_purchases]
  end

  # Downloads and reads are the proof, so they come first and page opens are capped on their
  # own. Each query is bounded; only the omitted count is a COUNT over the rest.
  def self.access_events(purchases)
    scope = ConsumptionEvent.where(purchase_id: purchases.map(&:id))
    order = Arel.sql("COALESCE(consumed_at, created_at), id")
    others = scope.where(event_type: ACCESS_LABELS.keys - [ConsumptionEvent::EVENT_TYPE_VIEW])
    views = scope.where(event_type: ConsumptionEvent::EVENT_TYPE_VIEW)
    kept = others.order(order).limit(MAX_ACCESSES_PER_PURCHASE).pluck(:event_type, :consumed_at, :created_at) +
           views.order(order).limit(MAX_VIEWS_PER_PURCHASE).pluck(:event_type, :consumed_at, :created_at)
    entries = kept.map { |type, consumed_at, created_at| [type, consumed_at || created_at] }
                  .map { |type, at| "#{ACCESS_LABELS.fetch(type)} #{fmt(at)}" }
    [entries, others.count + views.count - kept.size]
  end

  def self.fmt(time) = time.utc.strftime("%Y-%m-%d %H:%M:%S")
end
