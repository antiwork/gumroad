# frozen_string_literal: true

require "test_helper"

class CommunityChatRecapRunTest < ActiveSupport::TestCase
  self.described_class = CommunityChatRecapRun



  context_ CommunityChatRecapRun do
    subject(:recap_run) { build(:community_chat_recap_run) }

  context_ "associations" do
      it { is_expected.to have_many(:community_chat_recaps).dependent(:destroy) }
    end

  context_ "validations" do
      it { is_expected.to validate_presence_of(:from_date) }
      it { is_expected.to validate_presence_of(:to_date) }
      it { is_expected.to validate_uniqueness_of(:recap_frequency).scoped_to([:from_date, :to_date]) }
      it { is_expected.to validate_presence_of(:recap_frequency) }
      it { is_expected.to define_enum_for(:recap_frequency)
                          .with_values(daily: "daily", weekly: "weekly")
                          .backed_by_column_of_type(:string)
                          .with_prefix(:recap_frequency) }
    end

  context_ "scopes" do
  context_ ".running" do
  test "returns only runs without finished_at timestamp" do
          running_run = create(:community_chat_recap_run, from_date: 1.day.ago.beginning_of_day, to_date: 1.day.ago.end_of_day)
          finished_run = create(:community_chat_recap_run, :finished, from_date: 2.day.ago.beginning_of_day, to_date: 2.day.ago.end_of_day)

          expect(described_class.running).to include(running_run)
          expect(described_class.running).not_to include(finished_run)
        end
      end

  context_ ".finished" do
  test "returns only runs with finished_at timestamp" do
          running_run = create(:community_chat_recap_run, from_date: 1.day.ago.beginning_of_day, to_date: 1.day.ago.end_of_day)
          finished_run = create(:community_chat_recap_run, :finished, from_date: 2.day.ago.beginning_of_day, to_date: 2.day.ago.end_of_day)

          expect(described_class.finished).to include(finished_run)
          expect(described_class.finished).not_to include(running_run)
        end
      end

  context_ ".between" do
  test "returns runs within the specified date range" do
          from_date = 3.days.ago.beginning_of_day
          to_date = 1.day.ago.end_of_day

          in_range_run = create(:community_chat_recap_run, from_date:, to_date:)
          before_range_run = create(:community_chat_recap_run, from_date: 5.days.ago.beginning_of_day, to_date: 4.days.ago.end_of_day)
          after_range_run = create(:community_chat_recap_run, from_date: Date.today.beginning_of_day, to_date: Date.tomorrow.end_of_day)

          result = described_class.between(from_date, to_date)
          expect(result).to include(in_range_run)
          expect(result).not_to include(before_range_run)
          expect(result).not_to include(after_range_run)
        end
      end
    end

  context_ "#finished?" do
  test "returns true when finished_at is present" do
        recap_run = build(:community_chat_recap_run, finished_at: Time.current)
        expect(recap_run.finished?).to be true
      end

  test "returns false when finished_at is nil" do
        recap_run = build(:community_chat_recap_run, finished_at: nil)
        expect(recap_run.finished?).to be false
      end
    end

  context_ "#check_if_finished!" do
      let(:recap_run) { create(:community_chat_recap_run, recaps_count: 3) }

  context_ "when already finished" do
        before { recap_run.update!(finished_at: 1.hour.ago) }

  test "does not update finished_at" do
          original_finished_at = recap_run.finished_at
          recap_run.check_if_finished!

          expect(recap_run.reload.finished_at).to eq(original_finished_at)
        end
      end

  context_ "when there are pending recaps" do
        before do
          create(:community_chat_recap, community_chat_recap_run: recap_run)
          create(:community_chat_recap, :finished, community_chat_recap_run: recap_run)
        end

  test "does not mark as finished" do
          recap_run.check_if_finished!

          expect(recap_run.reload.finished_at).to be_nil
        end
      end

  context_ "when all recaps are finished or failed" do
        before do
          create(:community_chat_recap, :finished, community_chat_recap_run: recap_run)
          create(:community_chat_recap, :finished, community_chat_recap_run: recap_run)
          create(:community_chat_recap, :failed, community_chat_recap_run: recap_run)
        end

  test "marks as finished" do
          expect do
            recap_run.check_if_finished!
          end.to change { recap_run.reload.finished_at }.from(nil)

          expect(recap_run.finished_at).to be_within(2.second).of(Time.current)
        end
      end

  context_ "when the recaps_count doesn't match processed recaps" do
        before do
          recap_run.update!(recaps_count: 4)
          create(:community_chat_recap, :finished, community_chat_recap_run: recap_run)
          create(:community_chat_recap, :finished, community_chat_recap_run: recap_run)
          create(:community_chat_recap, :failed, community_chat_recap_run: recap_run)
        end

  test "does not mark as finished" do
          recap_run.check_if_finished!

          expect(recap_run.reload.finished_at).to be_nil
        end
      end
    end

  context_ "callbacks" do
  context_ "after_save_commit" do
  context_ "#trigger_weekly_recap_run" do
          let(:saturday) { Date.new(2025, 3, 22) } # A Saturday
          let(:sunday) { Date.new(2025, 3, 23) } # A Sunday

  context_ "when a daily recap run finishes for a Saturday" do
            let(:recap_run) { create(:community_chat_recap_run, from_date: saturday) }

  test "enqueues a weekly recap run job with the correct date" do
              expected_date = (saturday - 6.days).to_date.to_s

              expect do
                recap_run.update!(finished_at: Time.current)
              end.to change { TriggerCommunityChatRecapRunJob.jobs.size }.by(1)

              expect(TriggerCommunityChatRecapRunJob).to have_enqueued_sidekiq_job("weekly", expected_date)
            end
          end

  context_ "when daily recap finishes on a non-Saturday" do
            let(:recap_run) { build(:community_chat_recap_run, recap_frequency: "daily", from_date: sunday) }

  test "does not enqueue a weekly recap run job" do
              expect do
                recap_run.update!(finished_at: Time.current)
              end.not_to change { TriggerCommunityChatRecapRunJob.jobs.size }
            end
          end

  context_ "when a weekly recap run finishes" do
            let(:recap_run) { create(:community_chat_recap_run, :weekly, from_date: saturday - 6.days) }

  test "does not enqueue any other recap run job" do
              expect do
                recap_run.update!(finished_at: Time.current)
              end.not_to change { TriggerCommunityChatRecapRunJob.jobs.size }
            end
          end

  context_ "when run is not finished" do
            let(:recap_run) { build(:community_chat_recap_run, from_date: saturday) }

  test "does not enqueue a weekly recap run job" do
              expect do
                recap_run.save!
              end.not_to change { TriggerCommunityChatRecapRunJob.jobs.size }
            end
          end
        end

  context_ "#send_recap_notifications" do
          let(:recap_run) { create(:community_chat_recap_run) }

  context_ "when run is marked as finished" do
  test "enqueues a notification job" do
              expect do
                recap_run.update!(finished_at: Time.current)
              end.to change { SendCommunityChatRecapNotificationsJob.jobs.size }.by(1)

              expect(SendCommunityChatRecapNotificationsJob).to have_enqueued_sidekiq_job(recap_run.id)
              expect(recap_run.reload.notified_at).to be_within(2.second).of(Time.current)
            end
          end

  context_ "when run is already notified" do
            before { recap_run.update!(notified_at: 1.hour.ago) }

  test "does not enqueue a notification job" do
              expect do
                recap_run.update!(finished_at: Time.current)
              end.not_to change { SendCommunityChatRecapNotificationsJob.jobs.size }
            end
          end

  context_ "when run is not finished" do
  test "does not enqueue a notification job" do
              expect do
                recap_run.save!
              end.not_to change { SendCommunityChatRecapNotificationsJob.jobs.size }
            end
          end
        end
      end
    end
  end
end
