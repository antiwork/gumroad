# frozen_string_literal: true

class SendPostBlastEmailsJob
  include Sidekiq::Job
  include ActionView::Helpers::SanitizeHelper
  # Deliberately no `lock: :until_executed`. The digest keys on the blast id, and every caller
  # creates a fresh blast row before enqueuing, so it never deduplicated anything — but a hard-killed
  # worker skips its release, and the held digest then drops every later `perform_async` for that
  # blast silently, which is what made the documented recovery a no-op (gumroad-private#1816).
  sidekiq_options retry: 10, queue: :default

  # True when the sender has already handed every recipient it picked to an ESP.
  #
  # The sender publishes how many recipients it still owes (see `start_pending_recipients`),
  # and only decrements after the provider call returns — so a kill anywhere before the
  # handoff leaves a positive count. A missing key means "unknown", not "delivered": the
  # caller falls back to resuming, exactly as it did before this existed.
  def self.fully_delivered?(blast)
    return false if blast.completed_at.present?

    pending = $redis.get(RedisKey.blast_pending_recipients(blast.id))
    pending.present? && pending.to_i <= 0
  end

  def perform(blast_id)
    @blast = PostEmailBlast.find(blast_id)
    @post = @blast.post
    Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} post_id=#{@post.id}")
    return unless @post.alive? && @post.published? && @post.send_emails? && @blast.completed_at.nil?

    @blast.update!(started_at: Time.current) if @blast.started_at.nil?

    @filters = @post.audience_members_filter_params
    # The filter query can be expensive to run, it's better to run it on the replica DB.
    Makara::Context.release_all
    @members = load_audience_members

    if @blast.to_non_openers?
      keep_emails = load_non_opener_emails
      @members.select! { _1.email.present? && keep_emails.include?(_1.email.downcase) }
      remove_members_already_sent_in_this_blast
    else
      # We will check each batch of emails to see if they were already messaged,
      # but we can already remove all of the ones we know have already been emailed, ahead of time (faster).
      # This check is only useful if the post has been published twice, or if this job is being retried.
      remove_already_emailed_members
    end

    return mark_blast_as_completed if @members.empty?
    unless SellerLargeBlastQuota.allow?(
      seller_id: @post.seller_id,
      kind: "post_blast",
      blast_id: @blast.id,
      recipient_count: @members.size
    )
      requeue_for_daily_blast_limit
      return
    end

    start_pending_recipients
    cache = {}
    @members.each_slice(recipients_slice_size) do |members_slice|
      members_slice.group_by { PostEmailApi.provider_for(post: @post, email: _1.email) }.each do |provider, provider_members|
        provider_members.each_slice(PostEmailApi.max_recipients_for(provider)) do |provider_members_slice|
          send_provider_slice(provider: provider, members: provider_members_slice, cache: cache)
        end
      end
    end

    mark_blast_as_completed
  end

  private
    # How long the audience snapshot survives in Redis. Long enough to cover the full
    # Sidekiq retry schedule of this job (10 retries spans roughly a day), short enough
    # that an abandoned blast doesn't hold hundreds of thousands of entries forever.
    AUDIENCE_SNAPSHOT_TTL = 3.days

    # How many snapshotted member ids to revalidate per statement. Small on purpose:
    # MySQL's range optimizer has a memory budget for representing an `IN (...)` list as
    # primary-key ranges, and once the list is big enough to blow that budget it silently
    # abandons the primary key and looks the rows up through the (seller_id, email) index
    # instead — which for a seller with a six-figure audience means searching that
    # seller's whole membership per statement rather than the ids the slice asked for.
    # Measured on production against the real 350k-member audience: the plan holds
    # `range`/`PRIMARY` up to 6,000 ids and has flipped to `ref`/seller_id_and_email by
    # 6,500, with no error to tell you it happened. The cost shows up as tail latency —
    # ~57 ms per statement at 1,000 ids versus ~600-1,200 ms at 10,000 — so a slow
    # replica or a busy window is far likelier to push a 10,000-id statement into the
    # execution cap. Total revalidation wall time is roughly the same either way (the
    # work is proportional to the audience, not the slice count), so 1,000 buys tail
    # safety at no throughput cost. It leaves ~6x headroom under the measured flip.
    REVALIDATION_SLICE_SIZE = 1_000

    # Redis list/set writes only — no SQL — so this can stay large.
    REDIS_WRITE_SLICE_SIZE = 10_000

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

    # Loads the recipient list for the blast. For sellers with very large audiences
    # (hundreds of thousands of members) the filter query is the slowest, most fragile
    # part of the job: it can exceed the database's default 5-minute statement cap, and a
    # deploy or worker restart mid-run loses all its progress. Two protections here:
    #
    # 1. The query runs under a raised statement-time cap (Redis-tunable), the same way
    #    the sales report jobs handle long queries.
    # 2. The resolved member ids are snapshotted in Redis keyed by blast id. When a retry
    #    of the SAME blast runs after a mid-run kill (deploys will only get more
    #    frequent), it re-runs the filter restricted to just those ids — cheap,
    #    primary-key-bound — instead of the unrestricted filter over the whole audience,
    #    so each retry resumes sending within seconds instead of repaying the
    #    minutes-long load and re-racing the next deploy.
    #
    # Because the retry re-applies the ORIGINAL filter criteria to the snapshotted ids,
    # anyone whose eligibility changed after the snapshot was taken (unsubscribed,
    # erased, refunded the qualifying purchase, removed as an affiliate) is dropped from
    # the retry rather than emailed from stale data. Members ADDED after the first
    # attempt won't be picked up by a retry — acceptable for a send already mid-flight.
    def load_audience_members
      snapshot_key = RedisKey.blast_audience_snapshot(@blast.id)
      snapshotted_ids = $redis.lrange(snapshot_key, 0, -1)

      if snapshotted_ids.empty?
        members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
          AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
        end
        write_audience_snapshot(snapshot_key, members)
        members
      else
        Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} resuming from audience snapshot (#{snapshotted_ids.size} members)")
        revalidate_snapshotted_members(snapshotted_ids.map(&:to_i))
      end
    end

    # A snapshot can be up to a day old by the time the last retry runs, and audience
    # membership changes in that window: buyers refund, followers unsubscribe, affiliates
    # get removed. Simply checking that the audience_members row still exists is not
    # enough — a person with multiple relationships to the seller (e.g. a customer who
    # also follows) KEEPS their row when they leave just one role, so a follower who
    # unsubscribed (but also bought something) would still be emailed by a follower
    # blast from the stale snapshot.
    #
    # So the retry re-runs the SAME audience filter the first attempt used, restricted
    # to the snapshotted ids. Primary-key-bounding every subquery (the `ids:` option)
    # makes this cheap even for huge audiences — unlike the unrestricted filter the
    # snapshot exists to avoid — while re-checking every original criterion (role,
    # bought products, price/date bounds). The filter also returns FRESH rows, so the
    # send uses current emails and current purchase/follower/affiliate ids rather than
    # anything stale from the first attempt.
    def revalidate_snapshotted_members(snapshotted_ids)
      # Even though each slice is primary-key-bounded, the audience filter still joins
      # several large tables per slice, and for six-figure audiences a slice can exceed
      # the database's default statement cap. Every RETRY of a large blast goes through
      # this path (the first attempt wrote the snapshot), so an unraised cap here means
      # retries fail deterministically and the job dead-sets even though the fresh-load
      # path above is protected. Run the revalidation under the same raised,
      # Redis-tunable cap the fresh load uses.
      members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
        snapshotted_ids.each_slice(REVALIDATION_SLICE_SIZE).flat_map do |ids_slice|
          AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true, ids: ids_slice)
            .select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
        end
      end

      dropped = snapshotted_ids.size - members.size
      Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} dropped #{dropped} snapshotted members no longer in the audience") if dropped > 0
      members
    end

    # Writes the snapshot to a temporary key first, then atomically renames it into
    # place. The retry path treats ANY non-empty list at the real key as the complete
    # audience, so a worker killed partway through the slice-by-slice write must never
    # leave a partial list there — that would make a retry send to a fraction of the
    # audience and mark the blast completed. With the rename, the real key either
    # doesn't exist (retry re-runs the filter) or is complete with its TTL already set.
    def write_audience_snapshot(snapshot_key, members)
      return if members.empty?

      tmp_key = "#{snapshot_key}:tmp"
      $redis.del(tmp_key)
      members.each_slice(REDIS_WRITE_SLICE_SIZE) do |slice|
        $redis.rpush(tmp_key, slice.map(&:id))
      end
      $redis.expire(tmp_key, AUDIENCE_SNAPSHOT_TTL.to_i)
      $redis.rename(tmp_key, snapshot_key)
    end

    # Resolves which of the post's original recipients never opened it — the audience a
    # "resend to non-openers" blast targets.
    #
    # For a post emailed to hundreds of thousands of people this computation is the
    # slowest part of the whole job (it reads every open-tracking row for the post and
    # then looks up those buyers' emails), and it used to be repeated in full by every
    # attempt. That made large resends effectively un-sendable: each attempt needed
    # roughly an hour before the first email went out, and any deploy or worker recycle
    # in that window killed it and sent the next attempt back to the start.
    #
    # So the resolved set is checkpointed in Redis keyed by blast id, the same way the
    # audience snapshot is. A restarted attempt reads the checkpoint and proceeds
    # straight to sending. The set is still a point-in-time answer: someone who opens
    # the original email after the checkpoint is written may still receive the resend.
    # That was already true within a single attempt, and it is a far better outcome than
    # a blast that never sends at all.
    def load_non_opener_emails
      checkpoint_key = RedisKey.blast_non_opener_emails(@blast.id)
      if $redis.exists?(checkpoint_key)
        emails = $redis.smembers(checkpoint_key).to_set
        Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} resuming from non-opener checkpoint (#{emails.size} emails)")
        return emails
      end

      # The underlying queries read in primary-key-bounded batches, but the raised,
      # Redis-tunable statement cap stays as a second line of defence: it covers the
      # audience-filter query inside the same phase and any single batch that is slower
      # than expected on a heavily loaded replica.
      emails = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
        @post.unopened_recipient_emails.to_set
      end
      write_non_opener_checkpoint(checkpoint_key, emails)
      emails
    end

    # Same atomic write as the audience snapshot: build the set under a temporary key and
    # rename it into place, so an attempt killed partway through the write can never
    # leave a partial set that a later attempt would mistake for the complete answer and
    # send to a fraction of the non-openers.
    def write_non_opener_checkpoint(checkpoint_key, emails)
      return if emails.empty?

      tmp_key = "#{checkpoint_key}:tmp"
      $redis.del(tmp_key)
      emails.each_slice(REDIS_WRITE_SLICE_SIZE) do |slice|
        $redis.sadd(tmp_key, slice)
      end
      $redis.expire(tmp_key, AUDIENCE_SNAPSHOT_TTL.to_i)
      $redis.rename(tmp_key, checkpoint_key)
    end

    def prepare_recipients(members)
      members_with_specifics = members.index_with { { email: _1.email } }
      enrich_with_gathered_records(members_with_specifics)
      enrich_with_purchases_specifics(members_with_specifics)
      enrich_with_url_redirects(members_with_specifics)
      members_with_specifics.values
    end

    def remove_already_emailed_members
      already_sent_emails = Set.new(@post.sent_post_emails.pluck(:email))
      return if already_sent_emails.empty?

      @members.delete_if { _1.email.in?(already_sent_emails) }
    end

    BLAST_DEDUPE_TTL = 7.days

    def remove_members_already_sent_in_this_blast
      already_sent = $redis.smembers(RedisKey.blast_sent_emails(@blast.id))
      return if already_sent.empty?

      already_sent_set = already_sent.to_set
      @members.delete_if { already_sent_set.include?(_1.email) }
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

    # Publishes how many recipients this attempt still owes the ESPs, so a monitor can tell a
    # blast that died mid-send from one that died after the last handoff but before the stamp
    # below (gumroad-private#2250). Written per attempt, after filtering: a retry owes only
    # what is left. The TTL matches the audience snapshot — past it the answer is "unknown"
    # and the monitor falls back to resuming.
    def start_pending_recipients
      $redis.set(RedisKey.blast_pending_recipients(@blast.id), @members.size, ex: AUDIENCE_SNAPSHOT_TTL.to_i)
    end

    def decrement_pending_recipients(count)
      $redis.decrby(RedisKey.blast_pending_recipients(@blast.id), count)
    end

    def mark_blast_as_completed
      @blast.update!(completed_at: Time.current)
      # The blast is done, so the retry-resume snapshot, the non-opener checkpoint and the
      # pending-recipient count have served their purpose. Also remove the temporary
      # write-in-progress keys in case a previous attempt died mid-write (they carry a TTL,
      # but no reason to keep them around).
      snapshot_key = RedisKey.blast_audience_snapshot(@blast.id)
      checkpoint_key = RedisKey.blast_non_opener_emails(@blast.id)
      $redis.del(snapshot_key, "#{snapshot_key}:tmp", checkpoint_key, "#{checkpoint_key}:tmp",
                 RedisKey.blast_pending_recipients(@blast.id))
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

    # Tunable via Redis so a stuck blast can be unblocked without a deploy.
    def audience_load_timeout_seconds
      ($redis.get(RedisKey.audience_member_load_max_execution_time_seconds) || 1.hour).to_i
    end

    def requeue_for_daily_blast_limit
      job_id = self.class.perform_at(Time.zone.tomorrow.beginning_of_day, @blast.id)
      return if job_id.present?

      raise "Sidekiq did not requeue the blast for the daily limit"
    end
end
