# frozen_string_literal: true

require "spec_helper"

describe CommunityChatRecapMailer do
  describe "community_chat_recap_notification" do
    let(:user) { create(:user) }
    let(:seller) { create(:user, name: "John Doe") }
    let(:product) { create(:product, user: seller, name: "Snap app") }
    let!(:community) { create(:community, seller:, resource: product) }

    context "when sending daily recap" do
      let(:recap_run) { create(:community_chat_recap_run, :finished, from_date: Date.parse("Mar 26, 2025").beginning_of_day, to_date: Date.parse("Mar 26, 2025").end_of_day) }
      let!(:community_chat_recap) { create(:community_chat_recap, :finished, community:, community_chat_recap_run: recap_run, summary: "<ul><li>Creator welcomed everyone to the community.</li><li>A customer asked about using <strong>a specific feature</strong>.</li><li>Creator provided detailed instructions on how to use the feature.</li><li>Two customers expressed their gratitude for the information and help.</li></ul>", summarized_message_count: 10) }
      subject(:mail) { described_class.community_chat_recap_notification(user.id, seller.id, [community_chat_recap.id]) }

      it "emails to user with daily recap" do
        expect(mail.to).to eq([user.form_email])
        expect(mail.subject).to eq("Your daily John Doe community recap: March 26, 2025")
        expect(mail.body).to have_text("Here's a quick daily summary of what's been happening in John Doe community.")
        expect(mail.body).to have_text("# Snap app")
        expect(mail.body.encoded).to include("<li>Creator welcomed everyone to the community.</li>")
        expect(mail.body.encoded).to include("<li>A customer asked about using <strong>a specific feature</strong>.</li>")
        expect(mail.body.encoded).to include("<li>Creator provided detailed instructions on how to use the feature.</li>")
        expect(mail.body.encoded).to include("<li>Two customers expressed their gratitude for the information and help.</li>")
        expect(mail.body.encoded).to include("10 messages summarised")
        expect(mail.body.encoded).to have_link("Join the conversation", href: community_url(seller.external_id, community.external_id))
        expect(mail.body).to have_text("You are receiving this email because you're part of the John Doe community. To stop receiving daily recap emails, please update your notification settings.")
        expect(mail.body.encoded).to have_link("update your notification settings", href: community_url(seller.external_id, community.external_id, notifications: "true"))
      end
    end

    context "when sending weekly recap" do
      let(:from_date) { Date.parse("Mar 17, 2025").beginning_of_day }
      let(:weekly_recap_run) { create(:community_chat_recap_run, :weekly, from_date:, to_date: (from_date + 6.days).end_of_day) }
      let!(:weekly_recap) { create(:community_chat_recap, :finished, community:, community_chat_recap_run: weekly_recap_run, summary: "<ul><li>The <strong>new version of the app</strong> was shared by the creator, along with a confirmed <strong>release date</strong> for Android.</li><li>Customers raised concerns regarding various <strong>product issues</strong>, which the creator acknowledged and assured would be addressed in the <strong>next version</strong>.</li></ul>", summarized_message_count: 104) }
      let(:product2) { create(:product, user: seller, name: "Bubbles app") }
      let(:community2) { create(:community, seller:, resource: product2) }
      let!(:weekly_recap2) { create(:community_chat_recap, :finished, community: community2, community_chat_recap_run: weekly_recap_run, summary: "<ul><li>Creator welcomed everyone to the community.</li><li>People discussed various <strong>product issues</strong>.</li></ul>", summarized_message_count: 24) }
      subject(:mail) { described_class.community_chat_recap_notification(user.id, seller.id, [weekly_recap.id, weekly_recap2.id]) }

      it "emails to user with weekly recap" do
        expect(mail.to).to eq([user.form_email])
        expect(mail.subject).to eq("Your weekly John Doe community recap: March 17-23, 2025")
        expect(mail.body).to have_text("Here's a weekly summary of what happened in John Doe community.")
        expect(mail.body).to have_text("# Snap app")
        expect(mail.body.encoded).to include("The <strong>new version of the app</strong> was shared by the creator")
        expect(mail.body.encoded).to include("Customers raised concerns regarding various <strong>product issues</strong>")
        expect(mail.body.encoded).to include("104 messages summarised")
        expect(mail.body).to have_text("# Bubbles app")
        expect(mail.body.encoded).to include("<li>Creator welcomed everyone to the community.</li>")
        expect(mail.body.encoded).to include("<li>People discussed various <strong>product issues</strong>.</li>")
        expect(mail.body.encoded).to include("24 messages summarised")
        expect(mail.body.encoded).to have_link("Join the conversation", href: community_url(seller.external_id, community.external_id))
        expect(mail.body).to have_text("You are receiving this email because you're part of the John Doe community. To stop receiving weekly recap emails, please update your notification settings.")
        expect(mail.body.encoded).to have_link("update your notification settings", href: community_url(seller.external_id, community.external_id, notifications: "true"))
      end

      context "when recap spans multiple months" do
        let(:from_date) { Date.new(2025, 12, 28) }
        let(:to_date) { Date.new(2026, 1, 3) }
        let(:weekly_recap_run) { create(:community_chat_recap_run, :weekly, from_date:, to_date:) }

        it "formats date range correctly in subject" do
          expect(mail.subject).to eq("Your weekly John Doe community recap: December 28, 2025-January 3, 2026")
        end
      end

      context "when recap spans different months in same year" do
        let(:from_date) { Date.new(2025, 3, 30) }
        let(:to_date) { Date.new(2025, 4, 5) }
        let(:weekly_recap_run) { create(:community_chat_recap_run, :weekly, from_date:, to_date:) }

        it "formats date range correctly in subject" do
          expect(mail.subject).to eq("Your weekly John Doe community recap: March 30-April 5, 2025")
        end
      end
    end
  end
end
