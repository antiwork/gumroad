# frozen_string_literal: true

require "spec_helper"
require "timeout"

# An unfollow whose audience row is locked by another writer still commits: Follower::AudienceMember rescues the lock
# timeout and leaves the row to RefreshAudienceMemberJob. Until that runs, the row still lists the ended follow, so
# it can't decide which role a member is sent in.
describe PostBlastSending, "choosing a member's role while their audience row still lists an ended follow", :defer_audience_refresh do
  self.use_transactional_tests = false

  before do
    @seller = create(:named_user)
    @product = create(:product, user: @seller)
    @buyer_follow = create(:active_follower, user: @seller, email: "buyer-follower@example.com")
    @purchase = create(:purchase, :from_seller, seller: @seller, link: @product, email: @buyer_follow.email)
    @affiliate_user = create(:affiliate_user, email: "affiliate-follower@example.com")
    @affiliate = create(:direct_affiliate, seller: @seller, affiliate_user: @affiliate_user, send_posts: true)
    @affiliate.products << @product
    @affiliate_follow = create(:active_follower, user: @seller, email: @affiliate_user.email)
    @follow_only = create(:active_follower, user: @seller, email: "follow-only@example.com")
    @stayer = create(:active_follower, user: @seller, email: "stayer@example.com")
    RefreshAudienceMemberJob.drain
    @post = create(:audience_post, :published, seller: @seller)
    @blast = create(:blast, :just_requested, post: @post)
    @requests = []
    endpoint = double("SendGrid mail send")
    allow(endpoint).to receive(:post) do |request_body:|
      @requests << request_body["personalizations"].to_h do |personalization|
        [personalization["to"][0]["email"], { custom_args: personalization["custom_args"], unsubscribe_url: personalization["substitutions"]["{{unsubscribe_url}}"] }]
      end
      double(status_code: 202, body: "")
    end
    allow(SendGrid::API).to receive(:new).and_return(double(client: double(mail: double(_: endpoint))))
    [Resend::Batch, Resend::Emails].each do |sdk|
      allow(sdk).to receive(:send) do |payload|
        @requests << Array.wrap(payload).to_h { [_1[:to].sole, { custom_args: nil, unsubscribe_url: _1[:html][%r{href="([^"]*/(?:unsubscribe|cancel)[^"]*)"}, 1] }] }
        double(success?: true, body: "")
      end
    end
    allow(Rails.env).to receive(:test?).and_return(false)
    @settled = []
    allow_any_instance_of(SendPostBlastEmailsJob).to receive(:settle_pending_recipients).and_wrap_original do |original, skipped, owed|
      @settled << [skipped.map(&:email).sort, owed]
      original.call(skipped, owed)
    end
  end

  after do
    post_ids = Installment.where(seller_id: @seller.id).pluck(:id)
    SentPostEmail.where(post_id: post_ids).delete_all
    EmailInfo.where(installment_id: post_ids).delete_all
    PostEmailBlast.where(post_id: post_ids).delete_all
    UrlRedirect.where(installment_id: post_ids).delete_all
    Installment.where(id: post_ids).delete_all
    ProductAffiliate.where(affiliate_id: @affiliate.id).delete_all
    Affiliate.where(id: @affiliate.id).delete_all
    purchase_ids = Purchase.where(seller_id: @seller.id).pluck(:id)
    UrlRedirect.where(purchase_id: purchase_ids).delete_all
    Purchase.where(id: purchase_ids).delete_all
    product_ids = Link.where(user_id: @seller.id).pluck(:id)
    Link.where(id: product_ids).delete_all
    AudienceMember.where(seller_id: @seller.id).delete_all
    follower_ids = Follower.where(followed_id: @seller.id).pluck(:id)
    PaperTrail::Version.where(item_type: "Follower", item_id: follower_ids).delete_all
    Follower.where(id: follower_ids).delete_all
    @affiliate_user.destroy!
    @seller.destroy!
    UserComplianceInfo.where(user_id: [@seller.id, @affiliate_user.id]).delete_all
    delete_leftovers(user_ids: [@seller.id, @affiliate_user.id], product_ids:, installment_ids: post_ids)
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  # Ends these follows while another connection holds their audience rows, so each unfollow's row update waits out
  # this session's one-second lock wait, is rescued, and leaves the row to RefreshAudienceMemberJob.
  def unfollow_leaving_audience_rows_stale(*follows)
    member_ids = AudienceMember.where(seller_id: @seller.id, email: follows.map(&:email)).pluck(:id)
    locked = Queue.new
    release = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        connection.select_values("SELECT id FROM audience_members WHERE id IN (#{member_ids.join(",")}) FOR UPDATE")
        locked << true
        release.pop
      end
    end
    Timeout.timeout(10) { locked.pop }
    RefreshAudienceMemberJob.jobs.clear
    connection = ActiveRecord::Base.connection
    connection.execute("SET SESSION innodb_lock_wait_timeout = 1")
    follows.each { Follower.find(_1.id).mark_deleted! }
  ensure
    connection&.execute("SET SESSION innodb_lock_wait_timeout = DEFAULT")
    release << true
    holder&.join(10)
  end

  def expect_stale_rows_for(*follows)
    follows.each do |follow|
      expect(Follower.find(follow.id)).to be_deleted
      expect(AudienceMember.find_by!(seller_id: @seller.id, email: follow.email).details.dig("follower", "id")).to eq(follow.id)
    end
    expect(RefreshAudienceMemberJob.jobs.map { _1["args"] }).to match_array(follows.map { [_1.email, @seller.id] })
  end

  def sent = @requests.reduce({}, :merge)

  def expect_buyer_and_affiliate_sent_in_their_own_roles
    expect(sent.keys).to match_array([@buyer_follow.email, @affiliate_follow.email, @stayer.email])
    expect(sent[@buyer_follow.email][:unsubscribe_url]).to match(%r{/purchases/[^/]+/unsubscribe\z})
    expect(sent[@affiliate_follow.email][:unsubscribe_url]).to eq(Rails.application.routes.url_helpers.unsubscribe_posts_affiliate_url(@affiliate.external_id, Rails.application.config.action_mailer.default_url_options))
    expect(sent[@stayer.email][:unsubscribe_url]).to eq(Rails.application.routes.url_helpers.cancel_follow_url(@stayer.external_id, Rails.application.config.action_mailer.default_url_options))
    expect(SentPostEmail.where(post_id: @post.id).order(:email).pluck(:email)).to eq([@affiliate_follow.email, @buyer_follow.email, @stayer.email].sort)
    expect(@settled).to eq([[[@follow_only.email], 4]])
    expect(@blast.reload.delivery_count).to eq(3)
    expect(@blast.completed_at).to be_present
  end

  it "sends a buyer and an affiliate whose follow ended before the slice in those roles, and not the follow-only member" do
    allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
      unfollow_leaving_audience_rows_stale(@buyer_follow, @affiliate_follow, @follow_only) if Follower.find(@follow_only.id).alive?
      original.call(**kwargs)
    end

    SendPostBlastEmailsJob.new.perform(@blast.id)

    expect_stale_rows_for(@buyer_follow, @affiliate_follow, @follow_only)
    expect_buyer_and_affiliate_sent_in_their_own_roles
    expect(@requests.size).to eq(1)
    expect(sent[@buyer_follow.email][:custom_args]).to include("purchase_id" => @purchase.id.to_s).and(satisfy { !_1.key?("follower_id") })
    expect(sent[@affiliate_follow.email][:custom_args]).to include("affiliate_id" => @affiliate.id.to_s).and(satisfy { !_1.key?("follower_id") })
  end

  it "sends them again in those roles when their follow ends while the request is built" do
    built = 0
    allow_any_instance_of(PostSendgridApi).to receive(:build_mail).and_wrap_original do |original|
      request_body = original.call
      unfollow_leaving_audience_rows_stale(@buyer_follow, @affiliate_follow, @follow_only) if (built += 1) == 1
      request_body
    end

    SendPostBlastEmailsJob.new.perform(@blast.id)

    expect_stale_rows_for(@buyer_follow, @affiliate_follow, @follow_only)
    expect(@requests.map { _1.keys.sort }).to eq([[@stayer.email], [@affiliate_follow.email, @buyer_follow.email].sort])
    expect(@requests.last[@buyer_follow.email][:custom_args]).to include("purchase_id" => @purchase.id.to_s).and(satisfy { !_1.key?("follower_id") })
    expect(@requests.last[@affiliate_follow.email][:custom_args]).to include("affiliate_id" => @affiliate.id.to_s).and(satisfy { !_1.key?("follower_id") })
    expect_buyer_and_affiliate_sent_in_their_own_roles
  end

  it "does the same through Resend" do
    Feature.activate(:use_resend_for_post_emails)
    Feature.activate_user(:force_resend_for_post_emails, @seller)
    allow_any_instance_of(SendPostBlastEmailsJob).to receive(:send_provider_slice).and_wrap_original do |original, **kwargs|
      unfollow_leaving_audience_rows_stale(@buyer_follow, @affiliate_follow, @follow_only) if Follower.find(@follow_only.id).alive?
      original.call(**kwargs)
    end

    SendPostBlastEmailsJob.new.perform(@blast.id)

    expect_stale_rows_for(@buyer_follow, @affiliate_follow, @follow_only)
    expect_buyer_and_affiliate_sent_in_their_own_roles
  ensure
    Feature.deactivate(:use_resend_for_post_emails)
  end
end
