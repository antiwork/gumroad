# frozen_string_literal: true

# Read-only plan for replacing scheduled OneOffMailer jobs with FeatureAnnouncementMailer ones.
# The ledger maps user id to ActiveJob job id, so jobs are matched inside the raw payloads at the
# campaign's exact score, read in pages. Nothing is removed, enqueued or changed.
class Onetime::PlanFeatureAnnouncementReplacement
  PAGE_SIZE = 500
  ONE_OFF_KEYS = %i[email from subject body reply_to sender_domain].freeze

  def self.process(campaign:, ledger_key:, scheduled_at:, page_size: PAGE_SIZE)
    new(campaign:, ledger_key:, scheduled_at:, page_size:).process
  end

  def initialize(campaign:, ledger_key:, scheduled_at:, page_size:)
    @campaign = campaign
    @content = FeatureAnnouncementCampaign.find_by!(key: campaign)
    @ledger_key = ledger_key
    @score = scheduled_at.to_f
    @page_size = page_size
    @counts = Hash.new(0)
  end

  def process
    ledger = $redis.hgetall(@ledger_key).to_h { |user_id, job_id| [job_id, Integer(user_id)] }
    entries = []
    seen_job_ids = Set.new
    seen_addresses = Set.new

    each_scheduled_member do |member|
      job = parse(member)
      next @counts[:unrelated_job] += 1 if job.nil?

      user_id = ledger[job[:job_id]]
      if user_id.nil?
        @counts[:unmapped_campaign_job] += 1
        next
      end
      seen_job_ids << job[:job_id]

      outcome = check(job, user_id, seen_addresses)
      @counts[outcome] += 1
      entries << { user_id:, job_id: job[:job_id], jid: job[:jid], email: job[:args][:email], outcome: }
    end
    @counts[:ledger_job_not_scheduled] = (ledger.keys.to_set - seen_job_ids).size

    # Complete mapping is a precondition for a replacement, not permission to run one.
    blocking = @counts.slice(:unmapped_campaign_job, :ledger_job_not_scheduled, :content_mismatch).values.sum
    { mapping_complete: blocking.zero? && entries.any?, counts: @counts.dup, entries: }
  end

  private
    def each_scheduled_member
      offset = 0
      loop do
        page = Sidekiq.redis { _1.call("ZRANGEBYSCORE", "schedule", @score, @score, "LIMIT", offset, @page_size) }
        page.each { yield _1 }
        break if page.size < @page_size

        offset += @page_size
      end
    end

    # Returns the OneOffMailer#email job if this member carries the campaign subject, else nil.
    def parse(member)
      payload = JSON.parse(member)
      wrapped = Array(payload["args"]).first
      return unless payload["wrapped"] == "MailDeliveryJob" && wrapped.is_a?(Hash)

      mailer, method, delivery, params = ActiveJob::Arguments.deserialize(wrapped["arguments"])
      args = params.is_a?(Hash) ? Array(params[:args]).first : nil
      return unless args.is_a?(Hash) && args[:subject] == @content.subject

      { job_id: wrapped["job_id"], jid: payload["jid"], mailer:, method:, delivery:, args: args.symbolize_keys }
    rescue JSON::ParserError, ActiveJob::DeserializationError
      nil
    end

    def check(job, user_id, seen_addresses)
      args = job[:args]
      return :content_mismatch unless job.values_at(:mailer, :method, :delivery) == ["OneOffMailer", "email", "deliver_now"]
      return :content_mismatch unless (args.keys - ONE_OFF_KEYS).empty? && same_content?(args)

      user = User.find_by(id: user_id)
      return :user_missing if user.nil?
      return :account_inactive unless user.account_active?
      return :address_mismatch unless user.confirmed? && user.email.to_s.casecmp?(args[:email].to_s)
      return :duplicate_address unless seen_addresses.add?(args[:email].downcase)
      return :not_subscribed unless FeatureAnnouncementSubscription.subscribed?(user)

      :replaceable
    end

    # Markup can differ between the queued body and the mailer's; the words, links and bold
    # text cannot.
    def same_content?(args)
      args[:from] == FeatureAnnouncementMailer::FROM &&
        args[:reply_to] == @content.reply_to &&
        args[:sender_domain].to_s == FeatureAnnouncementMailer::SENDER_DOMAIN.to_s &&
        body_fingerprint(args[:body]) == body_fingerprint(@content.body)
    end

    def body_fingerprint(html)
      fragment = Nokogiri::HTML.fragment(html.to_s)
      text = fragment.xpath(".//text()").map { _1.text.squish }.reject(&:empty?)
      [text, fragment.css("a").map { _1["href"] }, fragment.css("strong, b").map { _1.text.squish }]
    end
end
