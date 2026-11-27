# frozen_string_literal: true

require "spec_helper"

describe "Post email blasts admin API", type: :request do
  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:named_user) }
  let(:headers) { { "Authorization" => "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}" } }
  let(:post_record) { create(:audience_post, :published, seller:) }
  let(:blast) { create(:blast, :just_requested, post: post_record, requested_at: 2.hours.ago) }
  let(:deferred_until) { Time.current.tomorrow.beginning_of_day + 5.hours }
  let(:path) { "/internal/admin/post_email_blasts/#{blast.id}/send_now" }

  before do
    headers
    host! VALID_API_REQUEST_HOSTS.first
    Sidekiq::ScheduledSet.new.clear
    SendPostBlastEmailsJob.clear
  end

  after do
    SendPostBlastEmailsJob.clear
    $redis.del(RedisKey.blast_quota_admitted(blast.id), RedisKey.blast_quota_deferred_until(blast.id))
    Sidekiq::ScheduledSet.new.clear
  end

  def defer_blast!
    $redis.set(RedisKey.blast_quota_deferred_until(blast.id), deferred_until.utc.iso8601)
    schedule_copy(blast)
  end

  # Sidekiq runs in fake mode in specs, which never writes the real schedule set the override reads.
  def schedule_copy(for_blast)
    Sidekiq::Testing.disable! { SendPostBlastEmailsJob.perform_at(deferred_until, for_blast.id) }
  end

  it "sends a quota-deferred blast now, removes the overnight copy and comments on the seller" do
    defer_blast!
    other_blast = create(:blast, :just_requested, post: create(:audience_post, :published, seller:), requested_at: 1.hour.ago)
    schedule_copy(other_blast)
    expect(Sidekiq::ScheduledSet.new.size).to eq(2)

    post path, params: { reason: "Seller published two large emails; the earlier one lost the slot" }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true, "blast_id" => blast.id, "user_id" => seller.external_id, "removed_scheduled_copies" => 1)
    expect($redis.get(RedisKey.blast_quota_admitted(blast.id))).to be_present
    expect(Sidekiq::ScheduledSet.new.map { _1.args }).to eq([[other_blast.id]])
    expect(SendPostBlastEmailsJob.jobs.map { _1["args"] }).to eq([[blast.id]])
    comment = seller.comments.last
    expect(comment.author_id).to eq(admin_user.id)
    expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
    expect(comment.content).to include("post email blast #{blast.id}", "daily limit for large emails", "Seller published two large emails")
    expect(response.parsed_body["comment_id"]).to eq(comment.id)
    audit = AdminApiAuditLog.find_by!(action: "post_email_blasts.send_now")
    expect(audit).to have_attributes(target_type: "PostEmailBlast", target_id: blast.id, actor_user_id: admin_user.id)
  end

  it "does not touch the seller's slot for the day" do
    defer_blast!
    slot_key = RedisKey.seller_large_blast_quota(seller.id, Date.current)
    $redis.set(slot_key, "post_blast:999", ex: 1.hour.to_i)

    post path, params: { reason: "override" }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect($redis.get(slot_key)).to eq("post_blast:999")
  ensure
    $redis.del(slot_key)
  end

  it "requires a reason" do
    defer_blast!

    post path, params: { reason: "  " }, headers:, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["message"]).to eq("reason is required")
    expect($redis.exists?(RedisKey.blast_quota_admitted(blast.id))).to eq(false)
    expect(SendPostBlastEmailsJob.jobs).to be_empty
    expect(Comment.count).to eq(0)
  end

  it "returns 404 for an unknown blast" do
    post "/internal/admin/post_email_blasts/0/send_now", params: { reason: "x" }, headers:, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it "rejects the shared legacy token and a missing token" do
    defer_blast!
    legacy_actor = create(:admin_user)
    stub_const("GUMROAD_ADMIN_ID", legacy_actor.id)
    create(:admin_api_token, actor_user: legacy_actor, token_hash: AdminApiToken.hash_token("test-admin-token"))

    post path, params: { reason: "x" }, headers: { "Authorization" => "Bearer test-admin-token" }, as: :json
    expect(response).to have_http_status(:unauthorized)

    post path, params: { reason: "x" }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect($redis.exists?(RedisKey.blast_quota_admitted(blast.id))).to eq(false)
  end

  shared_examples "refuses and changes nothing" do |message|
    it "answers 409" do
      post path, params: { reason: "override" }, headers:, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["message"]).to include(message)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
      expect(Sidekiq::ScheduledSet.new.size).to eq(1)
      expect(seller.comments.count).to eq(0)
    end
  end

  context "when the blast is completed" do
    before { defer_blast!; blast.update!(completed_at: Time.current) }

    include_examples "refuses and changes nothing", "already completed"
  end

  context "when the blast is expired" do
    before { defer_blast!; blast.update!(expired_at: Time.current, expiry_reason: PostEmailBlast::EXPIRY_QUOTA) }

    include_examples "refuses and changes nothing", "expired"
  end

  context "when the blast already has a quota decision" do
    before { defer_blast!; $redis.set(RedisKey.blast_quota_admitted(blast.id), Time.current.utc.iso8601) }

    include_examples "refuses and changes nothing", "quota decision"
  end

  context "when the blast was already sent now" do
    it "refuses the second request" do
      defer_blast!
      post path, params: { reason: "first" }, headers:, as: :json
      expect(response).to have_http_status(:ok)

      post path, params: { reason: "second" }, headers:, as: :json

      expect(response).to have_http_status(:conflict)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(1)
      expect(seller.comments.count).to eq(1)
    end
  end

  context "when the blast has started delivering" do
    before { defer_blast!; blast.update!(first_email_delivered_at: Time.current) }

    include_examples "refuses and changes nothing", "already started delivering"
  end

  context "when the blast is not waiting for the daily limit" do
    it "refuses a blast with no deferral" do
      post path, params: { reason: "override" }, headers:, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["message"]).to include("not waiting for the daily limit")
      expect($redis.exists?(RedisKey.blast_quota_admitted(blast.id))).to eq(false)
    end

    it "refuses a blast whose deferral time has passed" do
      $redis.set(RedisKey.blast_quota_deferred_until(blast.id), 1.minute.ago.utc.iso8601)

      post path, params: { reason: "override" }, headers:, as: :json

      expect(response).to have_http_status(:conflict)
    end
  end
end
