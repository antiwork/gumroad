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
    @members = AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a

    # We will check each batch of emails to see if they were already messaged,
    # but we can already remove all of the ones we know have already been emailed, ahead of time (faster).
    # This check is only useful if the post has been published twice, or if this job is being retried.
    remove_already_emailed_members

    return mark_blast_as_completed if @members.empty?

    cache = {}
    @members.each_slice(recipients_slice_size) do |members_slice|
      members = store_recipients_as_sent(members_slice)
      recipients = prepare_recipients(members)

      begin
        PostEmailApi.process(post: @post, recipients:, cache:, blast: @blast)
      rescue => e
        # Delete the sent_post_emails records if there's an error with PostEmailApi.process
        # We cannot use `transaction` here because it exceeds the lock timeout.
        emails = members.map(&:email)
        SentPostEmail.where(post: @post, email: emails).delete_all
        raise e
      end
    end

    mark_blast_as_completed
  end

  private
    def prepare_recipients(members)
      members_with_specifics = members.to_h { [_1, { email: _1.email }] }
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
    end

    # Stores email addresses in SentPostEmail, just before sending the emails.
    # In the very unlikely situation an email is already present there, its member won't be returned.
    # "Unlikely situation" because we've already filtered the sent emails beforehand with `remove_already_emailed_members`,
    # this behavior only helps if an email is sent by something else in parallel, between the start and the end of this job.
    def store_recipients_as_sent(members)
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
