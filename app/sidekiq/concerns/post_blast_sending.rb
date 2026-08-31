# frozen_string_literal: true

# Shared send phase for parent and slice jobs; callers set @blast, @post, and @members.
module PostBlastSending
  include ActionView::Helpers::SanitizeHelper

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

  # The provider slice — not the mixed slice — is the retry unit. An ESP that has
  # already accepted its recipients must not be handed them again because a later
  # provider failed, so the cleanup below only rolls back the slice that raised.
  def send_provider_slice(provider:, members:, cache:)
    # Count the slice as handed over, not the post-dedupe remainder: anything
    # `store_recipients_as_sent` drops was already emailed by someone else.
    owed = members.size
    members = store_recipients_as_sent(members)
    recipients = prepare_recipients(members)

    begin
      deliver_provider_slice(provider: provider, recipients: recipients, cache: cache)
      mark_members_sent_in_this_blast(members) if @blast.to_non_openers?
      decrement_pending_recipients(owed)
    rescue Exception => e
      # Delete the sent_post_emails records if there's an error with the provider send.
      # We cannot use `transaction` here because it exceeds the lock timeout.
      # Rescuing Exception, not StandardError: a deploy's hard shutdown raises
      # Sidekiq::Shutdown (an Interrupt), and letting that skip the cleanup would leave
      # these recipients marked sent but never emailed — the retry filters them out as
      # already-emailed, so they are silently dropped from the blast.
      unless @blast.to_non_openers?
        emails = members.map(&:email)
        SentPostEmail.where(post: @post, email: emails).delete_all
      end
      raise e
    end
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

  # Stores email addresses in SentPostEmail, just before sending the emails.
  # In the very unlikely situation an email is already present there, its member won't be returned.
  # "Unlikely situation" because we've already filtered the sent emails beforehand with `remove_already_emailed_members`,
  # this behavior only helps if an email is sent by something else in parallel, between the start and the end of this job.
  def store_recipients_as_sent(members)
    return members if @blast.to_non_openers?

    emails = Set.new(SentPostEmail.insert_all_emails(post: @post, emails: members.map(&:email)))
    return members if members.size == emails.size

    members.select { _1.email.in?(emails) }
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
