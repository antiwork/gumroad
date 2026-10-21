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

  # How long a sent-in-this-blast marker survives for a non-opener resend's dedupe. Kept for
  # the full scan window: it is the only record of who already received the resend, so a
  # late resume with no audience snapshot refuses to run once it is gone.
  BLAST_DEDUPE_TTL = AlertOnStalledPostEmailBlastsJob::LOOKBACK

  # How long the per-chunk completion set survives. Long enough that the last children of a
  # multi-hour blast can finish and stamp `completed_at`; an abandoned shell just expires and
  # the monitor flags the blast via the (positive) pending count instead.
  SLICE_DONE_TTL = 3.days

  # In-process attempts for the sent-row write that runs after the ESP accepted a slice.
  POST_ACCEPT_WRITE_ATTEMPTS = 3

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

  # One recipient can carry many purchases; the provider's recipient limit does not
  # bound this IN list. Keep live eligibility reads below MySQL's range-plan limit.
  PURCHASE_REVALIDATION_SLICE_SIZE = 1_000

  # Parent retries pass the full audience; keep each SISMEMBER pipeline bounded.
  SKIP_MEMBERSHIP_SLICE_SIZE = 1_000

  # Publishes how many recipients this attempt still owes the ESPs, so a monitor can tell a
  # blast that died mid-send from one that died after the last handoff but before the stamp
  # below (gumroad-private#2250). Written per attempt, after filtering: a retry owes only
  # what is left. The TTL matches the stalled-blast scan window so old incomplete blasts
  # can still be distinguished from completed-but-unstamped ones.
  def start_pending_recipients
    $redis.set(RedisKey.blast_pending_recipients(@blast.id), @members.size, ex: PENDING_RECIPIENTS_TTL.to_i)
  end

  def send_members(members)
    cache = {}
    members.each_slice(recipients_slice_size) do |members_slice|
      members_slice.group_by { PostEmailApi.provider_for(post: @post, email: _1.email) }.each do |provider, provider_members|
        provider_members.each_slice(PostEmailApi.max_recipients_for(provider)) do |provider_members_slice|
          return if @stopped_for_retired_newsletter || stop_for_retired_newsletter?
          send_provider_slice(provider: provider, members: provider_members_slice, cache: cache)
        end
      end
    end
  end

  # Checked before every provider slice, so chunks queued or mid-send when the newsletter retires stop at
  # the next one; the handoff itself is admitted against retire! (send_provider_slice), and a slice the
  # provider already accepted is not recalled. The stop is terminal even after delivery began, and the
  # blast's Redis state goes with it, so the stalled-blast monitor and the seller's page don't treat it as
  # owed. Callers must not record a stopped send as done.
  def stop_for_retired_newsletter?
    return false unless @post.audience_type? || @post.follower_type?
    return false unless FeatureAnnouncementNewsletterCutover.retired_for?(@post.seller_id)

    stop_for_retired_newsletter!
  end

  def stop_for_retired_newsletter!
    Rails.logger.warn("[#{self.class.name}] blast_id=#{@blast.id} stopped: newsletter retired for seller #{@post.seller_id}")
    PostEmailBlast.stop_for_retired_newsletter(@blast.id)
    clear_blast_state
    SellerLargeBlastQuota.release(seller_id: @post.seller_id, blast_id: @blast.id, kind: "post_blast")
    @stopped_for_retired_newsletter = true
  end

  # The provider slice — not the mixed slice — is the retry unit: an ESP that has already
  # accepted its recipients is never handed them again because a later provider failed.
  #
  # sent_post_emails rows are written AFTER the provider accepts. Written before, any exit a
  # rescue cannot see (SIGKILL, OOM) leaves rows that every retry then treats as sent, and the
  # blast completes short with no signal. A kill between acceptance and the write costs at most
  # one duplicate provider slice, which is visible and bounded.
  def send_provider_slice(provider:, members:, cache:)
    renew_chunk_claim! if respond_to?(:renew_chunk_claim!, true)
    # Skipped first: a recipient an earlier execution already charged and recorded must not be
    # sent to or charged twice. The count is then taken BEFORE the sent-row filter, because an
    # execution is charged for every member the published count still holds — including one whose
    # row was written by an execution that died before its own decrement.
    members = drop_members_already_skipped_from_audience(members)
    owed = members.size
    members = drop_members_already_sent(members)
    kept, dropped = partition_members_that_left_the_audience(members)
    if kept.empty?
      settle_pending_recipients(dropped, owed)
      return
    end

    withheld = hand_off_members(provider:, members: kept, cache:)
    return if withheld.nil?

    # The handoff withholds a follower whose follow ended after the audience load. On an audience post that member
    # can still be a buyer or an affiliate: recheck their row, which the unfollow already updated, and send them
    # once more as that. Anyone withheld again is settled like everyone else who left the audience.
    if withheld.any? && @post.audience_type?
      resend, withheld = partition_members_that_left_the_audience(withheld)
      if resend.any?
        withheld_again = hand_off_members(provider:, members: resend, cache:)
        return if withheld_again.nil?

        withheld += withheld_again
      end
    end
    settle_pending_recipients(dropped + withheld, owed)
  end

  # Renders these members, hands them to the provider and records the ones it took, before any further call.
  # Returns the members the handoff withheld, or nil once the newsletter retired.
  def hand_off_members(provider:, members:, cache:)
    withheld_emails = Set.new
    begin
      deliver_provider_slice(provider:, recipients: prepare_recipients(members), cache:, on_withheld: ->(withheld) { withheld_emails.merge(withheld.pluck(:email)) })
    rescue FeatureAnnouncementNewsletterCutover::Retired
      stop_for_retired_newsletter!
      return
    end
    withheld, delivered = members.partition { withheld_emails.include?(_1.email) }
    if @blast.to_non_openers?
      mark_members_sent_in_this_blast(delivered)
    else
      store_recipients_as_sent(delivered)
    end
    withheld
  end

  def deliver_provider_slice(provider:, recipients:, cache:, on_withheld:)
    args = { post: @post, recipients:, cache:, blast: @blast, on_withheld: }
    admission = FeatureAnnouncementNewsletterCutover.handoff_admission_for(@post)
    args[:handoff_admission] = admission if admission
    case provider
    when MailerInfo::EMAIL_PROVIDER_RESEND
      PostResendApi.process(**args)
    when MailerInfo::EMAIL_PROVIDER_SENDGRID
      PostSendgridApi.process(**args)
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
    clear_blast_state
  end

  def clear_blast_state(keep_quota_decision: false)
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
                 RedisKey.blast_active_slice_partition(@blast.id), partition_chunks_key,
                 RedisKey.blast_quota_deferred_until(@blast.id), (RedisKey.blast_quota_admitted(@blast.id) unless keep_quota_decision),
                 RedisKey.blast_skipped_emails(@blast.id)].compact)
  end

  # Re-checked right before each provider call: the chunk-level filter ran once at the start
  # of a slice that can take minutes, and another sender may have emailed some of these since.
  # Non-opener resends dedupe through their per-blast Redis set instead.
  def drop_members_already_sent(members)
    return members if @blast.to_non_openers?

    already_sent = @post.sent_post_emails.where(email: members.map(&:email)).pluck(:email).to_set
    return members if already_sent.empty?

    members.reject { already_sent.include?(_1.email) }
  end

  # Recheck live purchase eligibility at the provider handoff: the audience row is
  # rebuilt out of band, so a slice can still carry someone who has since left.
  # Matching this post's targeting can only ever remove a recipient.
  def partition_members_that_left_the_audience(members)
    return [members, []] if members.empty?
    # A follower or affiliate post reaches people the purchase predicate says nothing about.
    buyer_post = @post.seller_or_product_or_variant_type?
    return [members, []] unless buyer_post || @post.audience_type?

    details_by_member_id = AudienceMember.where(id: members.map(&:id)).select(:id, :details).index_by(&:id)
    purchase_ids = details_by_member_id.values.flat_map { Array.wrap(_1.details["purchases"]).pluck("id") }.uniq
    eligible_purchase_ids = purchase_ids.each_slice(PURCHASE_REVALIDATION_SLICE_SIZE).flat_map do |ids|
      Purchase.includes(:subscription).where(id: ids).filter_map { |purchase| purchase.id if purchase.should_be_audience_member? }
    end
    # Apply the original detail predicates and MAX(purchase_id) after removing ineligible
    # purchases, retaining the cutoff when the parent rebuilt a dated audience.
    qualifying_purchase_ids = if eligible_purchase_ids.empty?
      {}
    else
      AudienceMember.filter(seller_id: @post.seller_id, params: audience_filters, with_ids: true,
                            ids: members.map(&:id), purchase_ids: eligible_purchase_ids, as_of: @audience_as_of)
        .pluck(:id, :purchase_id).to_h
    end
    allow_non_purchase_recipients = !buyer_post && !purchase_targeted?
    # The row can still list a follow that has ended: an unfollow that times out updating it leaves it to
    # RefreshAudienceMemberJob. So the follow itself decides whether a member is sent as a follower.
    live_follower_ids = buyer_post ? Set.new : PostFollowerHandoff.live_follower_ids(@post.seller_id, members.select(&:follower_id).to_h { [_1.follower_id, _1.email] })

    kept, dropped = members.partition do |member|
      details = details_by_member_id[member.id]&.details || {}
      # A member is sent only in a role the audience load qualified them for and their row still holds, or as a
      # purchase that qualifies now. Other details on the row (an affiliation outside a date filter or added after
      # the load, a purchase that opted out) are no permission, and a member left with no role isn't sent.
      member.follower_id = nil if member.follower_id && (details.dig("follower", "id") != member.follower_id || !live_follower_ids.include?(member.follower_id))
      member.affiliate_id = nil if member.affiliate_id && Array.wrap(details["affiliates"]).none? { _1["id"] == member.affiliate_id }
      member.purchase_id = qualifying_purchase_ids[member.id]
      member.purchase_id.present? || (allow_non_purchase_recipients && (member.follower_id || member.affiliate_id).present?)
    end
    Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} dropped #{dropped.size} recipients who left the audience") if dropped.any?
    [kept, dropped]
  end

  # Audience selection uses bought_* filters, not the post's own link/variant.
  # A product (or variant) post with only not_bought_* still reaches buyers of
  # other products; treating link_id as required targeting would drop all of them.
  def purchase_targeted?
    audience_filters.values_at(:bought_product_ids, :bought_variant_ids).any?(&:present?)
  end

  def audience_filters
    @filters || @post.audience_members_filter_params
  end

  def drop_members_already_skipped_from_audience(members)
    return members if members.empty?

    key = RedisKey.blast_skipped_emails(@blast.id)
    return members unless $redis.exists?(key)

    members.each_slice(SKIP_MEMBERSHIP_SLICE_SIZE).flat_map do |slice|
      flags = $redis.pipelined do |pipe|
        slice.each { |member| pipe.sismember(key, member.email) }
      end
      slice.zip(flags).filter_map { |member, skipped| member unless skipped == true || skipped == 1 }
    end
  end

  # Records this slice's skips and charges them to the published count in one atomic step.
  # Split into two calls, a crash in between leaves a member marked as skipped — that marker is
  # what makes a retry drop them — with the count still charged for them, and no later execution
  # can settle it.
  def settle_pending_recipients(skipped, owed)
    emails = skipped.map(&:email)
    key = RedisKey.blast_skipped_emails(@blast.id)
    pending_key = RedisKey.blast_pending_recipients(@blast.id)
    results = $redis.multi do |tx|
      unless emails.empty?
        tx.sadd(key, emails)
        tx.expire(key, PENDING_RECIPIENTS_TTL.to_i)
      end
      tx.decrby(pending_key, owed)
      tx.ttl(pending_key)
    end
    # A stop or completion that cleared the key mid-call leaves DECRBY to recreate it with no expiry.
    $redis.expire(pending_key, PENDING_RECIPIENTS_TTL.to_i) if results.last == -1
  end

  # Only after the provider accepted, so a row here always has an email behind it. A transient
  # DB error now converts into a redelivered slice on the job retry, so absorb those in-process
  # first; a persistent failure still raises — the retry's redelivery is bounded and visible,
  # a swallowed write is a silent dedupe hole.
  def store_recipients_as_sent(members)
    attempts = 0
    begin
      # Rows nobody is holding are committed first, so a member a long erasure has locked holds back only
      # its own row: if waiting for it times out, the rest of the accepted slice is already recorded.
      unlocked_ids = store_recipients_still_at_their_address(members, lock: "FOR SHARE SKIP LOCKED")
      store_recipients_still_at_their_address(members.reject { unlocked_ids.include?(_1.id) }, lock: "FOR SHARE")
    rescue StandardError
      attempts += 1
      raise if attempts >= POST_ACCEPT_WRITE_ATTEMPTS
      sleep(attempts)
      retry
    end
  end

  # The members were loaded before the unlocked provider call, so a GDPR erasure may have rewritten or
  # removed one since. Each row is share-locked and written only if it still holds the address: an erasure
  # that locked first is waited for and then seen, and one that locks second waits for this commit and
  # deletes the rows in its post-commit recheck. A member removed meanwhile gets no row, so if they
  # rejoin, this post can reach them once more.
  #
  # Returns the ids of the member rows it locked.
  def store_recipients_still_at_their_address(members, lock:)
    return Set.new if members.empty?

    ApplicationRecord.connected_to(role: :writing) do
      ApplicationRecord.transaction do
        current_emails = AudienceMember.where(id: members.map(&:id)).lock(lock).pluck(:id, :email).to_h
        emails = members.filter_map { _1.email if current_emails[_1.id] == _1.email }
        SentPostEmail.insert_all_emails(post: @post, emails:)
        current_emails.keys.to_set
      end
    end
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
