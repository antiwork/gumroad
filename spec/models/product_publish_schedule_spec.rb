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
    it "stores the seller-zone wall time as UTC" do
      schedule = schedule!("2026-12-02T09:30")

      expect(schedule.publish_at).to eq(Time.utc(2026, 12, 2, 17, 30))
      expect(schedule.status).to eq("scheduled")
    end

    it "requires the lead time" do
      expect { schedule!("2026-12-01T04:03") }.to raise_error(described_class::Invalid, /at least 5 minutes/)
    end

    it "rejects nonexistent and ambiguous local times around DST" do
      expect { schedule!("2027-03-14T02:30") }.to raise_error(described_class::Invalid, /doesn't exist/)
      expect { schedule!("2027-11-07T01:30") }.to raise_error(described_class::Invalid, /happens twice/)
    end

    it "rejects text, empty input and dates that do not exist" do
      ["tomorrow", "", nil, "2026-13-45T10:00", "2027-02-30T10:00"].each do |input|
        expect { schedule!(input) }.to raise_error(described_class::Invalid, /valid date/)
      end
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

    it "refuses a second schedule until the first is cancelled" do
      schedule!("2026-12-02T09:30")

      expect { schedule!("2026-12-03T09:30") }.to raise_error(described_class::Invalid, /already has a schedule/)
      expect(described_class.where(product:).pluck(:publish_at)).to eq([Time.utc(2026, 12, 2, 17, 30)])
    end

    it "replaces a failed schedule" do
      failed = create(:product_publish_schedule, product:, scheduled_by: seller, status: "failed", failure_message: "x", notice_sent_at: Time.current)

      replacement = schedule!("2026-12-02T09:30")

      expect(described_class.where(product:).ids).to eq([replacement.id])
      expect(replacement.id).not_to eq(failed.id)
      expect(replacement).to have_attributes(status: "scheduled", failure_message: nil, notice_sent_at: nil)
    end

    it "works for bundles" do
      bundle = create(:product, :bundle, user: seller, draft: true)
      expect(schedule!("2026-12-02T09:30", target: bundle)).to be_persisted
    end

    it "schedules a never-published draft that carries the editor's not-for-sale marker" do
      # Product creation marks every new draft `purchase_disabled_at` (LinksController#create); the
      # eligibility check must not read that as "unavailable".
      ui_draft = create(:product, user: seller, draft: true, purchase_disabled_at: Time.current)

      expect(schedule!("2026-12-02T09:30", target: ui_draft)).to be_persisted
    end

    it "still refuses a draft an admin took down" do
      product.update!(is_unpublished_by_admin: true)

      expect { schedule!("2026-12-02T09:30") }.to raise_error(described_class::Invalid)
    end
  end

  describe "#run!" do
    let!(:schedule) { schedule!("2026-12-01T05:00") }
    let(:due) { schedule.publish_at }

    it "publishes through publish! and records the outcome" do
      schedule.run!(now: due + 1.minute)

      expect(product.reload.draft?).to eq(false)
      expect(schedule.reload.status).to eq("published")
      expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
    end

    it "leaves the product unpublished and records a failure when late by more than five minutes" do
      schedule.run!(now: due + 6.minutes)

      expect(product.reload.draft?).to eq(true)
      expect(schedule.reload.status).to eq("failed")
    end

    it "fails safely when a publish gate trips at fire time" do
      create(:product_sales_hold, product:)
      schedule.run!(now: due + 1.minute)

      expect(product.reload.draft?).to eq(true)
      expect(schedule.reload).to have_attributes(status: "failed")
      expect(schedule.failure_message).to be_present
    end

    it "does nothing before the time is due" do
      expect(schedule.run!(now: due - 1.minute)).to be_nil
      expect(schedule.reload.status).to eq("scheduled")
      expect(product.reload.draft?).to eq(true)
    end

    it "publishes once when two jobs run for one schedule" do
      expect(schedule.run!(now: due + 1.minute)).to eq("published")
      expect(described_class.find(schedule.id).run!(now: due + 1.minute)).to be_nil
      expect(SendProductPublishScheduleNoticeJob.jobs.size).to eq(1)
    end

    it "does not resurrect a deleted product" do
      product.delete!
      expect(described_class.exists?(schedule.id)).to eq(false)

      schedule.run!(now: due + 1.minute)
      expect(product.reload.deleted_at).to be_present
      expect(product.draft?).to eq(true)
    end

    it "removes a claimed schedule without a notice when the product was deleted before the job published" do
      allow(Link).to receive(:find_by).and_wrap_original do |original, *args|
        product.update_columns(deleted_at: Time.current)
        original.call(*args)
      end

      expect(schedule.run!(now: due + 10.minutes)).to be_nil

      expect(described_class.exists?(schedule.id)).to eq(false)
      expect(product.reload.draft?).to eq(true)
      expect(SendProductPublishScheduleNoticeJob.jobs.size).to eq(0)
    end

    context "when a team member scheduled the publish" do
      let(:member) { create(:user) }
      let!(:schedule) do
        create(:team_membership, user: member, seller:, role: TeamMembership::ROLE_ADMIN)
        schedule!("2026-12-01T05:00", by: member)
      end

      it "publishes while the member keeps the role" do
        expect(schedule.run!(now: due + 1.minute)).to eq("published")
      end

      it "fails with a notice when the member left the team" do
        member.user_memberships.update_all(deleted_at: Time.current)

        schedule.run!(now: due + 1.minute)

        expect(schedule.reload).to have_attributes(status: "failed", failure_message: described_class::AUTHORITY_REVOKED_MESSAGE)
        expect(product.reload.draft?).to eq(true)
        expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
      end

      it "fails when the member was suspended after scheduling" do
        member.suspend_for_fraud!(author_name: "test")

        schedule.run!(now: due + 1.minute)

        expect(schedule.reload.status).to eq("failed")
        expect(product.reload.draft?).to eq(true)
      end
    end

    it "removes a claimed schedule when the draft was archived before the job published" do
      # The claim lands first, then the product becomes unavailable: the state is re-read at fire time.
      allow(Link).to receive(:find_by).and_wrap_original do |original, *args|
        product.update!(archived: true)
        original.call(*args)
      end

      schedule.run!(now: due + 1.minute)

      expect(product.reload.draft?).to eq(true)
      expect(described_class.exists?(schedule.id)).to eq(false)
    end

    it "honors an accepted schedule after the creation flag is turned off" do
      Feature.deactivate_user(:scheduled_product_publishing, seller)
      schedule.run!(now: due + 1.minute)
      expect(product.reload.draft?).to eq(false)
    end

    it "keeps the claim when the publish succeeded but recording it failed, then recovers it as published" do
      allow(SendProductPublishScheduleNoticeJob).to receive(:perform_async).and_raise(Redis::BaseConnectionError)
      expect { schedule.run!(now: due + 1.minute) }.to raise_error(Redis::BaseConnectionError)
      expect(product.reload.draft?).to eq(false)
      allow(SendProductPublishScheduleNoticeJob).to receive(:perform_async).and_call_original

      stale = described_class.find(schedule.id)
      stale.update_columns(status: "publishing", claimed_at: 1.hour.ago)
      stale.recover_stale_claim!

      expect(stale.reload.status).to eq("published")
      expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
    end

    it "keeps the claim when publish! raises after the product went live, then sends the success notice" do
      allow_any_instance_of(Link).to receive(:publish!).and_wrap_original do |m, *args|
        m.call(*args)
        raise Redis::BaseConnectionError
      end
      expect { schedule.run!(now: due + 1.minute) }.to raise_error(Redis::BaseConnectionError)
      expect(product.reload.draft?).to eq(false)
      expect(schedule.reload.status).to eq("publishing")

      travel_to(schedule.claimed_at + described_class::CLAIM_TIMEOUT + 1.minute) do
        DispatchProductPublishSchedulesJob.new.perform
        expect(schedule.reload.status).to eq("published")
        SendProductPublishScheduleNoticeJob.drain
      end
      expect(ActionMailer::Base.deliveries.map(&:subject)).to eq(["#{product.name} is live"])
    end

    it "does not finish a claim that another job took over" do
      stale = described_class.find(schedule.id)
      stale.update_columns(status: "publishing", claimed_at: 1.hour.ago)
      described_class.where(id: schedule.id).update_all(claimed_at: Time.current)

      expect(stale.recover_stale_claim!).to be_nil
      expect(schedule.reload.status).to eq("publishing")
      expect(SendProductPublishScheduleNoticeJob.jobs.size).to eq(0)
    end

    it "releases the claim on an infrastructure error so the dispatcher can try again" do
      allow_any_instance_of(Link).to receive(:publish!).and_raise(Redis::BaseConnectionError)
      expect { schedule.run!(now: due + 1.minute) }.to raise_error(Redis::BaseConnectionError)
      expect(schedule.reload.status).to eq("scheduled")
    end
  end

  describe "cancellation from every route" do
    let!(:schedule) { schedule!("2026-12-02T09:30") }

    it "removes the schedule on manual publish" do
      product.publish!
      expect(described_class.exists?(schedule.id)).to eq(false)
    end

    it "removes the schedule on delete" do
      product.delete!
      expect(described_class.exists?(schedule.id)).to eq(false)
    end

    it "removes the schedule on admin unpublish / takedown" do
      product.unpublish!(is_unpublished_by_admin: true)
      expect(described_class.exists?(schedule.id)).to eq(false)
    end

    it "removes the schedule when an admin takes down a draft created in the editor" do
      # LinksController#create marks every new draft purchase_disabled_at, so the takedown changes only a flag.
      product.update_columns(purchase_disabled_at: 1.day.ago)
      product.reload.unpublish!(is_unpublished_by_admin: true)
      expect(described_class.exists?(schedule.id)).to eq(false)
    end

    it "keeps the schedule on an unrelated edit" do
      product.update!(name: "Renamed")
      expect(schedule.reload.status).to eq("scheduled")
    end

    it "keeps a schedule the job has already claimed" do
      schedule.update_columns(status: "publishing", claimed_at: Time.current)
      product.delete!
      expect(schedule.reload.status).to eq("publishing")
    end
  end
end
