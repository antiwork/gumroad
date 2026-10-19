# frozen_string_literal: true

require "spec_helper"

describe Onetime::PlanFeatureAnnouncementReplacement do
  let(:send_at) { Time.utc(2026, 10, 19, 13) }
  let(:ledger_key) { "gp3664:ledger" }
  let(:content) { FeatureAnnouncementMailer::CAMPAIGNS.fetch("piracy_reports") }
  # The queued jobs were built separately, so their markup differs from the mailer's.
  let(:queued_body) { content[:body].delete("\n").gsub("<strong>", "<b>").gsub("</strong>", "</b>") }

  around do |example|
    previous = MailDeliveryJob.queue_adapter
    MailDeliveryJob.queue_adapter = :sidekiq
    Sidekiq::Testing.disable! { example.run }
  ensure
    MailDeliveryJob.queue_adapter = previous
  end

  # Enqueues the same way the existing campaign did: one OneOffMailer job per address.
  def queue_one_off(email:, at: send_at, **overrides)
    args = { email:, from: FeatureAnnouncementMailer::FROM, sender_domain: "creators", reply_to: content[:reply_to],
             subject: content[:subject], body: queued_body }.merge(overrides)
    OneOffMailer.email(**args).deliver_later(queue: "low", wait_until: at).job_id
  end

  def queue_for(user, **overrides)
    queue_one_off(email: user.email, **overrides).tap { $redis.hset(ledger_key, user.id, _1) }
  end

  def plan(page_size: 2)
    described_class.process(campaign: "piracy_reports", ledger_key:, scheduled_at: send_at, page_size:)
  end

  def subscribed_user(email)
    create(:user, email:).tap { FeatureAnnouncementSubscription.update_from_settings!(_1, subscribed: true, rendered_version: 0) }
  end

  it "maps every ledger entry to its scheduled payload without changing the queue" do
    users = %w[a b c d e].map { subscribed_user("#{_1}@example.com") }
    job_ids = users.map { queue_for(_1) }
    before_queue = Sidekiq.redis { _1.call("ZRANGE", "schedule", 0, -1, "WITHSCORES") }

    result = plan

    expect(result[:mapping_complete]).to be(true)
    expect(result[:counts]).to eq(replaceable: 5, ledger_job_not_scheduled: 0)
    expect(result[:entries].map { _1.slice(:user_id, :job_id, :email) })
      .to match_array(users.zip(job_ids).map { |user, job_id| { user_id: user.id, job_id:, email: user.email } })
    expect(result[:entries].map { _1[:jid] }).to all(be_present)
    expect(result[:entries].map { _1[:jid] }).not_to include(*job_ids)
    expect(Sidekiq.redis { _1.call("ZRANGE", "schedule", 0, -1, "WITHSCORES") }).to eq(before_queue)
  end

  it "reports users without Feature announcements consent instead of treating them as sendable" do
    queue_for(create(:user, email: "no-consent@example.com"))

    result = plan

    expect(result[:counts]).to include(not_subscribed: 1)
    expect(result[:counts]).not_to have_key(:replaceable)
  end

  it "is incomplete when a scheduled campaign job is missing from the ledger" do
    queue_for(subscribed_user("mapped@example.com"))
    queue_one_off(email: "unmapped@example.com")

    result = plan

    expect(result[:mapping_complete]).to be(false)
    expect(result[:counts]).to include(unmapped_campaign_job: 1, replaceable: 1)
  end

  it "is incomplete when a ledger job is not scheduled at the campaign time" do
    queue_for(subscribed_user("mapped@example.com"))
    $redis.hset(ledger_key, create(:user).id, SecureRandom.uuid)

    expect(plan).to include(mapping_complete: false, counts: include(ledger_job_not_scheduled: 1))
  end

  it "is incomplete when a queued job's copy differs from the approved copy" do
    queue_for(subscribed_user("mapped@example.com"), body: queued_body.sub("five reports", "ten reports"))

    expect(plan).to include(mapping_complete: false, counts: include(content_mismatch: 1))
  end

  it "flags a job whose address is no longer the account's confirmed email" do
    user = subscribed_user("current@example.com")
    queue_one_off(email: "previous@example.com").tap { $redis.hset(ledger_key, user.id, _1) }

    expect(plan[:counts]).to include(address_mismatch: 1)
  end

  it "flags accounts that are no longer active" do
    queue_for(subscribed_user("suspended@example.com").tap { _1.update!(user_risk_state: "suspended_for_fraud") })

    expect(plan[:counts]).to include(account_inactive: 1)
  end

  it "only reads the campaign's own score" do
    queue_for(subscribed_user("mapped@example.com"))
    queue_one_off(email: "later@example.com", at: send_at + 1.minute)
    queue_one_off(email: "other@example.com", subject: "Something else")

    expect(plan[:counts]).to eq(replaceable: 1, unrelated_job: 1, ledger_job_not_scheduled: 0)
  end
end
