# frozen_string_literal: true

require "test_helper"

class ForceFinishLongRunningCommunityChatRecapRunsJobTest < ActiveSupport::TestCase
  self.described_class = ForceFinishLongRunningCommunityChatRecapRunsJob



  context_ ForceFinishLongRunningCommunityChatRecapRunsJob do
    let(:job) { described_class.new }

  context_ "#perform" do
      let(:recap_run) { create(:community_chat_recap_run) }
      let(:community) { create(:community) }
      let!(:recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }

  context_ "when recap run is already finished" do
        before { recap_run.update!(finished_at: 1.hour.ago) }

  test "does nothing" do
          expect do
            expect do
              job.perform
            end.not_to change { recap.reload.status }
          end.not_to change { recap_run.reload.finished_at }
        end
      end

  context_ "when recap run is running but not old enough" do
        before { recap_run.update!(finished_at: nil, created_at: 1.hour.ago) }

  test "does not update any recaps" do
          expect do
            expect do
              job.perform
            end.not_to change { recap.reload.status }
          end.not_to change { recap_run.reload.finished_at }
        end
      end

  context_ "when recap run is running and old enough" do
        before { recap_run.update!(finished_at: nil, created_at: 7.hours.ago) }

  context_ "when recap is pending" do
  test "updates recap status to failed" do
            expect do
              job.perform
            end.to change { recap.reload.status }.from("pending").to("failed")
              .and change { recap.error_message }.to("Recap run cancelled because it took longer than 6 hours to complete")
              .and change { recap_run.reload.finished_at }.from(nil).to(be_present)
              .and change { recap_run.notified_at }.from(nil).to(be_present)
          end
        end

  context_ "when recap is not pending" do
          before { recap.update!(status: "finished") }

  test "does not update recap status" do
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
end
