# frozen_string_literal: true

require "spec_helper"

RSpec.describe SendCommunityChatRecapNotificationsJob do
  let(:job) { described_class.new }

  describe "#perform" do
    let(:recap_run) { create(:community_chat_recap_run) }
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, community_chat_enabled: true) }
    let(:community) { create(:community, seller:, resource: product) }
    let(:user) { create(:user) }
    let!(:recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }
    let!(:notification_setting) { create(:community_notification_setting, user:, seller:) }

    before do
      Feature.activate_user(:communities, seller)
    end

    context "when recap run is not finished" do
      it "does not send any notifications" do
        expect do
          job.perform(recap_run.id)
        end.not_to have_enqueued_mail(CommunityChatRecapMailer, :community_chat_recap_notification)
      end
    end

    context "when recap run is finished" do
      before { recap_run.update_column(:finished_at, 1.hour.ago) } # To prevent after_save_commit callback from triggering

      context "when no notification settings exist" do
        before do
          recap.update!(status: "finished")
          notification_setting.destroy!
        end

        it "does not send any notifications" do
          expect do
            job.perform(recap_run.id)
          end.not_to have_enqueued_mail(CommunityChatRecapMailer, :community_chat_recap_notification)
        end
      end

      context "when notification setting exists and recaps are finished" do
        before do
          recap.update!(status: "finished")
        end

        context "when user has accessible communities" do
          let!(:purchase) { create(:purchase, seller:, link: product, purchaser: user) }

          it "sends notification to user" do
            expect do
              job.perform(recap_run.id)
            end.to have_enqueued_mail(CommunityChatRecapMailer, :community_chat_recap_notification)
              .with(user.id, seller.id, [recap.id])
          end
        end

        context "when user has no accessible communities" do
          it "does not send notification" do
            expect do
              job.perform(recap_run.id)
            end.not_to have_enqueued_mail(CommunityChatRecapMailer, :community_chat_recap_notification)
          end
        end

        context "when seller has no communities" do
          before do
            product.update!(community_chat_enabled: false)
          end

          it "does not send notification" do
            expect do
              job.perform(recap_run.id)
            end.not_to have_enqueued_mail(CommunityChatRecapMailer, :community_chat_recap_notification)
          end
        end

        context "when an error occurs" do
          it "notifies Bugsnag" do
            expect(Bugsnag).to receive(:notify).with(ActiveRecord::RecordNotFound)

            job.perform("non-existing-id")
          end
        end
      end
    end
  end
end
