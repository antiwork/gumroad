# frozen_string_literal: true

class SendPostBlastEmailsJob
  include Sidekiq::Job
  include ActionView::Helpers::SanitizeHelper
  sidekiq_options retry: 10, queue: :default, lock: :until_executed

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
      keep_emails = @post.unopened_recipient_emails.to_set
      @members.select! { _1.email.present? && keep_emails.include?(_1.email.downcase) }
      remove_members_already_sent_in_this_blast
    else
      # We will check each batch of emails to see if they were already messaged,
      # but we can already remove all of the ones we know have already been emailed, ahead of time (faster).
      # This check is only useful if the post has been published twice, or if this job is being retried.
      remove_already_emailed_members
    end

    return mark_blast_as_completed if @members.empty?

    cache = {}
    @members.each_slice(recipients_slice_size) do |members_slice|
      members = store_recipients_as_sent(members_slice)
      recipients = prepare_recipients(members)

      begin
        PostEmailApi.process(post: @post, recipients:, cache:, blast: @blast)
        mark_members_sent_in_this_blast(members) if @blast.to_non_openers?
      rescue => e
        # Delete the sent_post_emails records if there's an error with PostEmailApi.process
        # We cannot use `transaction` here because it exceeds the lock timeout.
        unless @blast.to_non_openers?
          emails = members.map(&:email)
          SentPostEmail.where(post: @post, email: emails).delete_all
        end
        raise e
      end
    end

    mark_blast_as_completed
  end

  private
    # How long the audience snapshot survives in Redis. Long enough to cover the full
    # Sidekiq retry schedule of this job (10 retries spans roughly a day), short enough
    # that an abandoned blast doesn't hold hundreds of thousands of entries forever.
    AUDIENCE_SNAPSHOT_TTL = 3.days

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
      members = snapshotted_ids.each_slice(10_000).flat_map do |ids_slice|
        AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true, ids: ids_slice)
          .select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
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
      members.each_slice(10_000) do |slice|
        $redis.rpush(tmp_key, slice.map(&:id))
      end
      $redis.expire(tmp_key, AUDIENCE_SNAPSHOT_TTL.to_i)
      $redis.rename(tmp_key, snapshot_key)
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

      purchases = Purchase.joins(:link).where(id: purchase_ids).select(:id, :link_id, :json_data, :subscription_id, "links.name as product_name").index_by(&:id)
      members_with_specifics.each do |_member, specifics|
        purchase_id = specifics[:purchase]&.id
        next if purchase_id.nil?
        purchase = purchases[purchase_id]
        if purchase.link_id.present?
          specifics[:product_id] = purchase.link_id
          specifics[:product_name] = strip_tags(purchase.product_name)
        end
        specifics[:subscription] = Subscription.new(id: purchase.subscription_id) if purchase.subscription_id.present?
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

    def mark_blast_as_completed
      @blast.update!(completed_at: Time.current)
      # The blast is done, so the retry-resume snapshot has served its purpose. Also
      # remove the temporary write-in-progress key in case a previous attempt died
      # mid-write (it carries a TTL, but no reason to keep it around).
      snapshot_key = RedisKey.blast_audience_snapshot(@blast.id)
      $redis.del(snapshot_key, "#{snapshot_key}:tmp")
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
end
