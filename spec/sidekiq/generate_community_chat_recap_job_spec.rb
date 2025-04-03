# frozen_string_literal: true

require "spec_helper"

RSpec.describe GenerateCommunityChatRecapJob do
  subject(:job) { described_class.new }

  describe "#perform" do
    let(:recap_run) { create(:community_chat_recap_run) }
    let(:community) { create(:community) }
    let(:recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }

    it "generates the recap" do
      expect_any_instance_of(CommunityChatRecapGeneratorService).to receive(:process).and_call_original
      expect do
        job.perform(recap.id)
      end.to change { recap.reload.status }.from("pending").to("finished")
    end

    it "marks the corresponding recap run as finished when all associated recaps are finished" do
      expect_any_instance_of(CommunityChatRecapRun).to receive(:check_if_finished!).and_call_original

      expect do
        job.perform(recap.id)
      end.to change { recap_run.reload.finished? }.from(false).to(true)

      expect(recap_run.finished_at).to be_present
      expect(recap_run.notified_at).to be_present
    end

    it "does not mark the corresponding recap run as finished when not all associated recaps are finished" do
      recap2 = create(:community_chat_recap, community: create(:community), community_chat_recap_run: recap_run)

      expect do
        job.perform(recap.id)
      end.not_to change { recap_run.reload.finished? }

      expect(recap.reload).to be_status_finished
      expect(recap2.reload).to be_status_pending
      expect(recap_run.finished_at).to be_nil
      expect(recap_run.notified_at).to be_nil
    end

    it "marks the corresponding recap run as finished when all associated recaps are either finished or failed" do
      recap2 = create(:community_chat_recap, community: create(:community), community_chat_recap_run: recap_run, status: "failed")

      expect do
        job.perform(recap.id)
      end.to change { recap_run.reload.finished? }.from(false).to(true)

      expect(recap.reload).to be_status_finished
      expect(recap2.reload).to be_status_failed
      expect(recap_run.finished_at).to be_present
      expect(recap_run.notified_at).to be_present
    end
  end

  describe "sidekiq_retries_exhausted", :sidekiq_inline do
    let(:recap_run) { create(:community_chat_recap_run) }
    let(:community) { create(:community) }
    let(:recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }
    let(:error_message) { "OpenAI API error" }
    let(:job_info) { { "class" => "GenerateCommunityChatRecapJob", "args" => [recap.id] } }

    it "updates the failing recap status to failed" do
      expect_any_instance_of(CommunityChatRecapRun).to receive(:check_if_finished!).and_call_original

      expect do
        described_class::FailureHandler.call(job_info, StandardError.new(error_message))
      end.to change { recap.reload.status }.from("pending").to("failed")

      expect(recap).to be_status_failed
      expect(recap.error_message).to eq(error_message)
      expect(recap_run.reload).to be_finished
      expect(recap_run.notified_at).to be_present
    end
  end
end
