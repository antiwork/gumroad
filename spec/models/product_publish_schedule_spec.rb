# frozen_string_literal: true

require "spec_helper"

describe ProductPublishSchedule do
  let(:seller) { create(:named_seller, timezone: "Pacific Time (US & Canada)") }
  let(:product) { create(:product, user: seller, draft: true) }
  let(:now) { Time.utc(2026, 12, 1, 12, 0) }

  before { Feature.activate_user(:scheduled_product_publishing, seller) }

  def schedule!(local_time, target: product, by: seller)
    described_class.schedule!(product: target, scheduled_by: by, local_time:, now:)
  end

  describe ".schedule!" do
    it "stores the seller-zone wall time as UTC and enqueues the job" do
      schedule = schedule!("2026-12-02T09:30")

      expect(schedule.publish_at).to eq(Time.utc(2026, 12, 2, 17, 30))
      expect(PublishScheduledProductJob).to have_enqueued_sidekiq_job(schedule.id, schedule.version)
    end

    it "requires the lead time" do
      expect { schedule!("2026-12-01T04:03") }.to raise_error(described_class::Invalid, /at least 5 minutes/)
    end

    it "rejects nonexistent and ambiguous local times around DST" do
      expect { schedule!("2027-03-14T02:30") }.to raise_error(described_class::Invalid, /doesn't exist/)
      expect { schedule!("2027-11-07T01:30") }.to raise_error(described_class::Invalid, /happens twice/)
    end

    it "rejects garbage input" do
      expect { schedule!("tomorrow") }.to raise_error(described_class::Invalid, /valid date/)
    end

    it "is refused when the creation flag is off" do
      Feature.deactivate_user(:scheduled_product_publishing, seller)
      expect { schedule!("2026-12-02T09:30") }.to raise_error(described_class::Invalid, /isn't available/)
    end

    it "refuses published, previously published, deleted and preorder products" do
      published = create(:product, user: seller)
      expect { schedule!("2026-12-02T09:30", target: published) }.to raise_error(described_class::Invalid, /never been published/)

      product.update_columns(first_published_at: 1.day.ago)
      expect { schedule!("2026-12-02T09:30") }.to raise_error(described_class::Invalid, /never been published/)
    end

    it "refuses a product that already fails the publish checks" do
      create(:product_sales_hold, product:)
      expect { schedule!("2026-12-02T09:30") }.to raise_error(described_class::Invalid)
    end

    it "reschedules by bumping the version so the old job no-ops" do
      first = schedule!("2026-12-02T09:30")
      second = schedule!("2026-12-03T09:30")

      expect(second.id).to eq(first.id)
      expect(second.version).to eq(first.version + 1)
      PublishScheduledProductJob.new.perform(first.id, first.version)
      expect(product.reload.draft?).to eq(true)
    end

    it "works for bundles" do
      bundle = create(:product, :bundle, user: seller, draft: true)
      expect(schedule!("2026-12-02T09:30", target: bundle)).to be_persisted
    end
  end

  describe "#run!" do
    let!(:schedule) { schedule!("2026-12-01T05:00") }
    let(:due) { schedule.publish_at }

    it "publishes through publish! and records the outcome" do
      schedule.run!(expected_version: schedule.version, now: due + 1.minute)

      expect(product.reload.draft?).to eq(false)
      expect(schedule.reload.status).to eq("published")
      expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
    end

    it "leaves the product unpublished and records a failure when late by more than five minutes" do
      schedule.run!(expected_version: schedule.version, now: due + 6.minutes)

      expect(product.reload.draft?).to eq(true)
      expect(schedule.reload.status).to eq("failed")
    end

    it "fails safely when a publish gate trips at fire time" do
      create(:product_sales_hold, product:)
      schedule.run!(expected_version: schedule.version, now: due + 1.minute)

      expect(product.reload.draft?).to eq(true)
      expect(schedule.reload).to have_attributes(status: "failed")
      expect(schedule.failure_message).to be_present
    end

    it "does nothing before the time is due or with a stale version" do
      expect(schedule.run!(expected_version: schedule.version, now: due - 1.minute)).to be_nil
      expect(schedule.run!(expected_version: schedule.version - 1, now: due + 1.minute)).to be_nil
      expect(schedule.reload.status).to eq("scheduled")
    end

    it "does not resurrect a deleted product" do
      product.delete!
      expect(schedule.reload.status).to eq("cancelled")

      schedule.run!(expected_version: schedule.version, now: due + 1.minute)
      expect(product.reload.deleted_at).to be_present
      expect(product.draft?).to eq(true)
    end

    it "cancels when the scheduler lost authority" do
      member = create(:user)
      create(:team_membership, user: member, seller:, role: TeamMembership::ROLE_ADMIN)
      other = schedule!("2026-12-01T05:00", by: member)
      member.user_memberships.update_all(deleted_at: Time.current)

      other.run!(expected_version: other.version, now: due + 1.minute)
      expect(other.reload).to have_attributes(status: "cancelled", cancellation_reason: "authority_revoked")
      expect(product.reload.draft?).to eq(true)
    end

    it "honors an accepted schedule after the creation flag is turned off" do
      Feature.deactivate_user(:scheduled_product_publishing, seller)
      schedule.run!(expected_version: schedule.version, now: due + 1.minute)
      expect(product.reload.draft?).to eq(false)
    end

    it "releases the claim on an infrastructure error so the retry can run" do
      allow_any_instance_of(Link).to receive(:publish!).and_raise(Redis::BaseConnectionError)
      expect { schedule.run!(expected_version: schedule.version, now: due + 1.minute) }.to raise_error(Redis::BaseConnectionError)
      expect(schedule.reload.status).to eq("scheduled")
    end
  end

  describe "cancellation from every route" do
    let!(:schedule) { schedule!("2026-12-02T09:30") }

    it "cancels on manual publish" do
      product.publish!
      expect(schedule.reload).to have_attributes(status: "cancelled", cancellation_reason: "published_manually")
    end

    it "cancels on delete" do
      product.delete!
      expect(schedule.reload.status).to eq("cancelled")
    end

    it "cancels on admin unpublish / takedown" do
      product.unpublish!(is_unpublished_by_admin: true)
      expect(schedule.reload.status).to eq("cancelled")
    end

    it "does not cancel on an unrelated edit" do
      product.update!(name: "Renamed")
      expect(schedule.reload.status).to eq("scheduled")
    end
  end
end
