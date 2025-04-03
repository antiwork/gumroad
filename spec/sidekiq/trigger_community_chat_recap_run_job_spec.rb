# frozen_string_literal: true

require "spec_helper"

RSpec.describe TriggerCommunityChatRecapRunJob do
  subject(:job) { described_class.new }

  describe "#perform" do
    context "when recap_frequency is invalid" do
      it "raises ArgumentError" do
        expect { job.perform("invalid") }.to raise_error(ArgumentError, "Recap frequency must be daily or weekly")
      end
    end

    context "when recap_frequency is daily" do
      let(:from_date) { Date.yesterday.beginning_of_day }
      let(:to_date) { from_date.end_of_day }

      context "when no messages exist" do
        it "creates a daily recap run and marks it as finished" do
          expect do
            expect do
              job.perform("daily")
            end.to change(CommunityChatRecapRun, :count).by(1)
          end.not_to change(CommunityChatRecap, :count)

          expect(GenerateCommunityChatRecapJob.jobs).to be_empty

          recap_run = CommunityChatRecapRun.last
          expect(recap_run.recap_frequency_daily?).to eq(true)
          expect(recap_run.from_date.iso8601).to eq(from_date.iso8601)
          expect(recap_run.to_date.iso8601).to eq(to_date.iso8601)
          expect(recap_run.recaps_count).to eq(0)
          expect(recap_run.finished_at).to be_present
          expect(recap_run.notified_at).to be_present
        end
      end

      context "when messages exist" do
        let!(:community) { create(:community) }
        let!(:message) { create(:community_chat_message, community: community, created_at: from_date + 1.hour) }

        it "creates a pending daily recap run" do
          expect do
            job.perform("daily")
          end.to change(CommunityChatRecapRun, :count).by(1)
            .and change(CommunityChatRecap, :count).by(1)

          recap_run = CommunityChatRecapRun.last
          expect(recap_run.recap_frequency_daily?).to eq(true)
          expect(recap_run.from_date.iso8601).to eq(from_date.iso8601)
          expect(recap_run.to_date.iso8601).to eq(to_date.iso8601)
          expect(recap_run.recaps_count).to eq(1)
          expect(recap_run.finished_at).to be_nil
          expect(recap_run.notified_at).to be_nil

          recap = CommunityChatRecap.last
          expect(recap.community_id).to eq(community.id)
          expect(recap.community_chat_recap_run_id).to eq(recap_run.id)
          expect(recap).to be_status_pending

          expect(GenerateCommunityChatRecapJob).to have_enqueued_sidekiq_job(recap.id)
        end
      end

      context "when a recap run already exists" do
        let!(:existing_run) { create(:community_chat_recap_run, from_date:, to_date:) }

        it "does not create a new recap run" do
          expect do
            expect do
              job.perform("daily")
            end.not_to change(CommunityChatRecapRun, :count)
          end.not_to change(CommunityChatRecap, :count)

          expect(GenerateCommunityChatRecapJob.jobs).to be_empty
        end
      end

      context "when from_date is provided" do
        let(:custom_date) { 2.days.ago.to_date.to_s }

        it "uses the provided date" do
          expect do
            job.perform("daily", custom_date)
          end.to change(CommunityChatRecapRun, :count).by(1)

          recap_run = CommunityChatRecapRun.last
          expect(recap_run.recap_frequency_daily?).to eq(true)
          expect(recap_run.from_date.iso8601).to eq(Date.parse(custom_date).beginning_of_day.iso8601)
          expect(recap_run.to_date.iso8601).to eq(Date.parse(custom_date).end_of_day.iso8601)
        end
      end
    end

    context "when recap_frequency is weekly" do
      let(:from_date) { (Date.yesterday - 6.days).beginning_of_day }
      let(:to_date) { (from_date + 6.days).end_of_day }

      context "when no messages exist" do
        it "creates a weekly recap run and marks it as finished" do
          expect do
            expect do
              job.perform("weekly")
            end.to change(CommunityChatRecapRun, :count).by(1)
          end.not_to change(CommunityChatRecap, :count)

          expect(GenerateCommunityChatRecapJob.jobs).to be_empty

          recap_run = CommunityChatRecapRun.last
          expect(recap_run.recap_frequency_weekly?).to eq(true)
          expect(recap_run.from_date.iso8601).to eq(from_date.iso8601)
          expect(recap_run.to_date.iso8601).to eq(to_date.iso8601)
          expect(recap_run.recaps_count).to eq(0)
          expect(recap_run.finished_at).to be_present
          expect(recap_run.notified_at).to be_present
        end
      end

      context "when messages exist" do
        let!(:community) { create(:community) }
        let!(:message) { create(:community_chat_message, community: community, created_at: from_date + 1.day) }

        it "creates a pending weekly recap run" do
          expect do
            job.perform("weekly")
          end.to change(CommunityChatRecapRun, :count).by(1)
            .and change(CommunityChatRecap, :count).by(1)

          recap_run = CommunityChatRecapRun.last
          expect(recap_run.recap_frequency_weekly?).to eq(true)
          expect(recap_run.from_date.iso8601).to eq(from_date.iso8601)
          expect(recap_run.to_date.iso8601).to eq(to_date.iso8601)
          expect(recap_run.recaps_count).to eq(1)
          expect(recap_run.finished_at).to be_nil
          expect(recap_run.notified_at).to be_nil

          recap = CommunityChatRecap.last
          expect(recap.community_id).to eq(community.id)
          expect(recap.community_chat_recap_run_id).to eq(recap_run.id)
          expect(recap).to be_status_pending

          expect(GenerateCommunityChatRecapJob).to have_enqueued_sidekiq_job(recap.id)
        end
      end

      context "when a recap run already exists" do
        let!(:existing_run) { create(:community_chat_recap_run, :weekly, from_date:, to_date:) }

        it "does not create a new recap run" do
          expect do
            expect do
              job.perform("weekly")
            end.not_to change(CommunityChatRecapRun, :count)
          end.not_to change(CommunityChatRecap, :count)

          expect(GenerateCommunityChatRecapJob.jobs).to be_empty
        end
      end

      context "when from_date is provided" do
        let(:custom_date) { 14.days.ago.to_date.to_s }

        it "uses the provided date" do
          expect do
            job.perform("weekly", custom_date)
          end.to change(CommunityChatRecapRun, :count).by(1)

          recap_run = CommunityChatRecapRun.last
          expect(recap_run.recap_frequency_weekly?).to eq(true)
          expect(recap_run.from_date.iso8601).to eq(Date.parse(custom_date).beginning_of_day.iso8601)
          expect(recap_run.to_date.iso8601).to eq((Date.parse(custom_date) + 6.days).end_of_day.iso8601)
        end
      end
    end
  end
end
