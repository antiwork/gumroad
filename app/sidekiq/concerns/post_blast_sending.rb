# frozen_string_literal: true

# Shared send phase for parent and slice jobs; callers set @blast, @post, and @members.
module PostBlastSending
  extend ActiveSupport::Concern

  included do
    # strip_tags calls self.class.full_sanitizer; ClassMethods must land on the job.
    include ActionView::Helpers::SanitizeHelper
  end

  # Small counter key used by the stalled-blast monitor. Keep it for the full scan window;
  # unlike the audience snapshot, it is tiny and is the only evidence for late safe resumes.
  PENDING_RECIPIENTS_TTL = AlertOnStalledPostEmailBlastsJob::LOOKBACK

  # How long a sent-in-this-blast marker survives for a non-opener resend's dedupe.
  BLAST_DEDUPE_TTL = 7.days

  # How long the per-chunk completion set survives. Long enough that the last children of a
  # multi-hour blast can finish and stamp `completed_at`; an abandoned shell just expires and
  # the monitor flags the blast via the (positive) pending count instead.
  SLICE_DONE_TTL = 3.days

  SLICE_PARTITION_MUTATION_LOCK_TTL = 30.seconds
  SLICE_PARTITION_MUTATION_LOCK_WAIT = 5.seconds
  SLICE_PARTITION_MUTATION_LOCK_RETRY_INTERVAL = 0.05
  RELEASE_SLICE_PARTITION_MUTATION_LOCK = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  LUA

  # Same IN-list bound as SendPostBlastEmailsJob::REVALIDATION_SLICE_SIZE: past a few
  # thousand entries MySQL silently abandons the indexed plan, and the parent's first
  # attempt passes its full (six-figure) audience through here.
  ALREADY_EMAILED_SLICE_SIZE = 1_000

  # Publishes how many recipients this attempt still owes the ESPs, so a monitor can tell a
  # blast that died mid-send from one that died after the last handoff but before the stamp
  # below (gumroad-private#2250). Written per attempt, after filtering: a retry owes only
  # what is left. The TTL matches the stalled-blast scan window so old incomplete blasts
  # can still be distinguished from completed-but-unstamped ones.
  def start_pending_recipients
    $redis.set(RedisKey.blast_pending_recipients(@blast.id), @members.size, ex: PENDING_RECIPIENTS_TTL.to_i)
  end

  def decrement_pending_recipients(count)
    $redis.decrby(RedisKey.blast_pending_recipients(@blast.id), count)
  end

  def send_members(members)
    cache = {}
    members.each_slice(recipients_slice_size) do |members_slice|
      members_slice.group_by { PostEmailApi.provider_for(post: @post, email: _1.email) }.each do |provider, provider_members|
        provider_members.each_slice(PostEmailApi.max_recipients_for(provider)) do |provider_members_slice|
          send_provider_slice(provider: provider, members: provider_members_slice, cache: cache)
        end
      end
    end
  end

  # The provider slice — not the mixed slice — is the retry unit: an ESP that has already
  # accepted its recipients is never handed them again because a later provider failed.
  #
  # The sent_post_emails rows are written AFTER the provider accepts, never before. A
  # rescue-and-delete around a pre-write cannot be made airtight — SIGKILL, OOM, and a
  # rescue that itself raises all skip it — and every row it leaves behind is a recipient
  # `remove_already_emailed_members` filters out of every retry as "already sent", so the
  # blast completes with a hole nobody can see (gumroad-private#2366: ~1.7M recipients
  # across 147 blasts). A kill between the ESP accepting and the write landing costs one
  # duplicate email for that provider slice (<= 1,000); the pre-write ordering cost a
  # silent non-delivery for the same slice. Duplicates are visible and bounded.
  def send_provider_slice(provider:, members:, cache:)
    renew_chunk_claim! if respond_to?(:renew_chunk_claim!, true)
    owed = members.size
    members = drop_members_already_sent(members)
    return decrement_pending_recipients(owed) if members.empty?

    recipients = prepare_recipients(members)
    deliver_provider_slice(provider: provider, recipients: recipients, cache: cache)
    if @blast.to_non_openers?
      mark_members_sent_in_this_blast(members)
    else
      store_recipients_as_sent(members)
    end
    decrement_pending_recipients(owed)
  end

  def deliver_provider_slice(provider:, recipients:, cache:)
    case provider
    when MailerInfo::EMAIL_PROVIDER_RESEND
      PostResendApi.process(post: @post, recipients: recipients, cache: cache, blast: @blast)
    when MailerInfo::EMAIL_PROVIDER_SENDGRID
      PostSendgridApi.process(post: @post, recipients: recipients, cache: cache, blast: @blast)
    else
      raise ArgumentError, "Unknown email provider: #{provider}"
    end
  end

  def prepare_recipients(members)
    members_with_specifics = members.index_with { { email: _1.email } }
    enrich_with_gathered_records(members_with_specifics)
    enrich_with_purchases_specifics(members_with_specifics)
    enrich_with_url_redirects(members_with_specifics)
    members_with_specifics.values
  end

  def enrich_with_gathered_records(members_with_specifics)
    members_with_specifics.each do |member, specifics|
      if @post.seller_or_product_or_variant_type?
        specifics[:purchase] = Purchase.new(id: member.purchase_id) if member.purchase_id
      elsif @post.follower_type?
        specifics[:follower] = Follower.new(id: member.follower_id) if member.follower_id
      elsif @post.affiliate_type?
        specifics[:affiliate] = Affiliate.new(id: member.affiliate_id) if member.affiliate_id
      elsif @post.audience_type?
        specifics[:follower] = Follower.new(id: member.follower_id) if member.follower_id
        specifics[:affiliate] = Affiliate.new(id: member.affiliate_id) if member.follower_id.nil? && member.affiliate_id
        specifics[:purchase] = Purchase.new(id: member.purchase_id) if member.follower_id.nil? && member.affiliate_id.nil? && member.purchase_id
      end
      specifics.compact_blank!
    end
  end

  def enrich_with_purchases_specifics(members_with_specifics)
    purchase_ids = members_with_specifics.map { _2[:purchase]&.id }.compact
    return if purchase_ids.empty?

    purchases = Purchase.joins(:link).where(id: purchase_ids).select(:id, :link_id, :json_data, :subscription_id, :full_name, "links.name as product_name").index_by(&:id)
    members_with_specifics.each do |_member, specifics|
      purchase_id = specifics[:purchase]&.id
      next if purchase_id.nil?
      purchase = purchases[purchase_id]
      if purchase.link_id.present?
        specifics[:product_id] = purchase.link_id
        specifics[:product_name] = strip_tags(purchase.product_name)
      end
      specifics[:subscription] = Subscription.new(id: purchase.subscription_id) if purchase.subscription_id.present?
      # :purchase here is a bare Purchase.new(id:) stub, so the name has to be carried separately —
      # reading full_name off it would silently return nil for every recipient in a blast.
      specifics[:purchaser_name] = purchase.full_name if purchase.full_name.present?
    end
  end

  def enrich_with_url_redirects(members_with_specifics)
    return if !post_has_files? && !@post.product_or_variant_type?

    # Fetch url_redirect for this post * non-purchases.
    # Because all followers and affiliates will end up seeing the same page, we only need to create one record.
    if post_has_files?
      members_with_specifics.each do |_member, specifics|
        next if specifics.key?(:purchase)
        @url_redirect_for_non_purchasers ||= UrlRedirect.find_or_create_by!(installment_id: @post.id, purchase_id: nil, subscription_id: nil, link_id: nil)
        specifics[:url_redirect] = @url_redirect_for_non_purchasers
      end
    end

    # Create url_redirects for this post * purchases.
    url_redirects_to_create = {}

    members_with_specifics.each do |member, specifics|
      next if specifics.key?(:url_redirect)
      url_redirects_to_create[UrlRedirect.generate_new_token] = {
        attributes: {
          installment_id: @post.id,
          purchase_id: specifics[:purchase]&.id,
          subscription_id: specifics[:subscription]&.id,
          link_id: specifics[:product_id],
        },
        member:
      }
    end

    if url_redirects_to_create.present?
      UrlRedirect.insert_all!(url_redirects_to_create.map { _2[:attributes].merge(token: _1) })
      url_redirects = UrlRedirect.where(token: url_redirects_to_create.keys).select(:id, :token).to_a
      url_redirects.each do |url_redirect|
        members_with_specifics[url_redirects_to_create[url_redirect.token][:member]][:url_redirect] = url_redirect
      end
    end
  end

  def remove_members_already_sent_in_this_blast
    already_sent = $redis.smembers(RedisKey.blast_sent_emails(@blast.id))
    return if already_sent.empty?

    already_sent_set = already_sent.to_set
    @members.delete_if { already_sent_set.include?(_1.email) }
  end

  def remove_already_emailed_members
    emails = @members.map(&:email)
    return if emails.empty?

    already_sent_emails = Set.new
    emails.each_slice(ALREADY_EMAILED_SLICE_SIZE) do |emails_slice|
      already_sent_emails.merge(@post.sent_post_emails.where(email: emails_slice).pluck(:email))
    end
    return if already_sent_emails.empty?

    @members.delete_if { _1.email.in?(already_sent_emails) }
  end

  def mark_members_sent_in_this_blast(members)
    emails = members.map(&:email)
    return if emails.empty?

    key = RedisKey.blast_sent_emails(@blast.id)
    $redis.pipelined do |pipe|
      pipe.sadd(key, emails)
      pipe.expire(key, BLAST_DEDUPE_TTL.to_i)
    end
  end

  def with_slice_partition_lock
    token = SecureRandom.uuid
    key = RedisKey.blast_slice_partition_mutation_lock(@blast.id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SLICE_PARTITION_MUTATION_LOCK_WAIT
    lock_acquired = false

    until $redis.set(key, token, nx: true, ex: SLICE_PARTITION_MUTATION_LOCK_TTL.to_i)
      raise "slice partition is already changing for blast #{@blast.id}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep SLICE_PARTITION_MUTATION_LOCK_RETRY_INTERVAL
    end

    lock_acquired = true
    yield
  ensure
    $redis.eval(RELEASE_SLICE_PARTITION_MUTATION_LOCK, keys: [key], argv: [token]) if lock_acquired
  end

  def mark_blast_as_completed
    @blast.update!(completed_at: Time.current)
    # The blast is done, so the retry-resume snapshot, the non-opener checkpoint, the
    # pending-recipient count and the per-chunk completion set have served their purpose.
    # Also remove the temporary write-in-progress keys in case a previous attempt died
    # mid-write (they carry a TTL, but no reason to keep them around).
    snapshot_key = RedisKey.blast_audience_snapshot(@blast.id)
    checkpoint_key = RedisKey.blast_non_opener_emails(@blast.id)
    active_partition_key = $redis.get(RedisKey.blast_active_slice_partition(@blast.id))
    partition_chunks_key = active_partition_key && RedisKey.blast_slice_partition_chunks(@blast.id, active_partition_key)
    $redis.del(*[snapshot_key, "#{snapshot_key}:tmp", checkpoint_key, "#{checkpoint_key}:tmp",
                 RedisKey.blast_pending_recipients(@blast.id), RedisKey.blast_done_slices(@blast.id),
                 RedisKey.blast_active_slice_partition(@blast.id), partition_chunks_key].compact)
  end

  # Re-checked per provider slice, right before the send: the chunk-level filter ran once at
  # the start of a slice that can take minutes, and a second publish or a concurrent sender
  # may have emailed some of these addresses since. Non-opener resends dedupe through their
  # per-blast Redis set instead (`remove_members_already_sent_in_this_blast`).
  def drop_members_already_sent(members)
    return members if @blast.to_non_openers?

    already_sent = @post.sent_post_emails.where(email: members.map(&:email)).pluck(:email).to_set
    return members if already_sent.empty?

    members.reject { already_sent.include?(_1.email) }
  end

  # Records the slice as sent. Runs only after the provider accepted, so a row here always
  # has an email behind it. A concurrent sender racing the same address just loses the
  # unique-index race; the duplicate it already sent is the bounded cost.
  def store_recipients_as_sent(members)
    SentPostEmail.insert_all_emails(post: @post, emails: members.map(&:email))
  end

  def post_has_files?
    return @has_files if defined?(@has_files)
    @has_files = @post.has_files?
  end

  def product
    @post.link if @post.product_type? || @post.variant_type?
  end

  def recipients_slice_size
    @recipients_slice_size ||= begin
      $redis.get(RedisKey.blast_recipients_slice_size) || PostEmailApi.max_recipients
    end.to_i.clamp(1..PostEmailApi.max_recipients)
  end
end
