# frozen_string_literal: true

require "spec_helper"

RSpec.describe ForceFinishLongRunningCommunityChatRecapRunsJob do
  let(:job) { described_class.new }

  describe "#perform" do
    let(:recap_run) { create(:community_chat_recap_run) }
    let(:community) { create(:community) }
    let!(:recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }

    context "when recap run is already finished" do
      before { recap_run.update!(finished_at: 1.hour.ago) }

      it "does nothing" do
        expect do
          expect do
            job.perform
          end.not_to change { recap.reload.status }
        end.not_to change { recap_run.reload.finished_at }
      end
    end

    context "when recap run is running but not old enough" do
      before { recap_run.update!(finished_at: nil, created_at: 1.hour.ago) }

      it "does not update any recaps" do
        expect do
          expect do
            job.perform
          end.not_to change { recap.reload.status }
        end.not_to change { recap_run.reload.finished_at }
      end
    end

    context "when recap run is running and old enough" do
      before { recap_run.update!(finished_at: nil, created_at: 7.hours.ago) }

      context "when recap is pending" do
        it "updates recap status to failed" do
          expect do
            job.perform
          end.to change { recap.reload.status }.from("pending").to("failed")
            .and change { recap.error_message }.to("Recap run cancelled because it took longer than 6 hours to complete")
            .and change { recap_run.reload.finished_at }.from(nil).to(be_present)
            .and change { recap_run.notified_at }.from(nil).to(be_present)
        end
      end

      context "when recap is not pending" do
        before { recap.update!(status: "finished") }

        it "does not update recap status" do
          expect do
            expect do
              job.perform
            end.not_to change { recap.reload.status }
          end.to change { recap_run.reload.finished_at }.from(nil).to(be_present)
             .and change { recap_run.notified_at }.from(nil).to(be_present)

          expect(recap.error_message).to be_nil
        end
      end
    end
  end
end
