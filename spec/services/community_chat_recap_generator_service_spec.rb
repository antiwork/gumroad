# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityChatRecapGeneratorService do
  let(:seller) { create(:user) }
  let(:community) { create(:community, seller:) }

  describe "#process" do
    context "when recap is already finished" do
      let(:community_chat_recap) { create(:community_chat_recap, :finished) }

      it "returns early" do
        expect(OpenAI::Client).not_to receive(:new)
        expect do
          described_class.new(community_chat_recap:).process
        end.not_to change { community_chat_recap.reload }
      end
    end

    context "when generating daily recap" do
      let(:recap_run) { create(:community_chat_recap_run, from_date: Date.yesterday.beginning_of_day, to_date: Date.yesterday.end_of_day) }
      let(:community_chat_recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }

      before do
        [
          { user: seller, content: "Welcome to the community!" },
          { user: nil, content: "How do I use this feature?" },
          { user: seller, content: "Here's how to use it..." },
          { user: nil, content: "Thank you for the information!" },
          { user: seller, content: "I'm grateful for the help!" },
          { user: nil, content: "You're welcome!" }].each.with_index do |message, i|
          user = message[:user] || create(:user)
          create(:community_chat_message, community:, user:, content: message[:content], created_at: Date.yesterday.beginning_of_day + (i + 1).hours)
        end
      end

      it "generates a summary from chat messages" do
        VCR.use_cassette("community_chat_recap_generator/daily_summary") do
          described_class.new(community_chat_recap: community_chat_recap).process
        end

        expect(community_chat_recap.reload).to be_status_finished
        expect(community_chat_recap.summary).to match(/<ul>.*?<\/ul>/m)
        expect(community_chat_recap.summary.scan("</li>").count).to eq(4)
        expect(community_chat_recap.summary).to include("<li>Creator welcomed everyone to the community.</li>")
        expect(community_chat_recap.summary).to include("<li>A customer asked about using a specific feature.</li>")
        expect(community_chat_recap.summary).to include("<li>Creator provided detailed instructions on how to use the feature.</li>")
        expect(community_chat_recap.summary).to include("<li>Two customers expressed their gratitude for the information and help.</li>")
        expect(community_chat_recap.summarized_message_count).to eq(6)
        expect(community_chat_recap.input_token_count).to eq(429)
        expect(community_chat_recap.output_token_count).to eq(67)
      end

      it "handles no messages in the given period" do
        CommunityChatMessage.destroy_all

        described_class.new(community_chat_recap: community_chat_recap).process

        expect(community_chat_recap.reload).to be_status_finished
        expect(community_chat_recap.summary).to be_empty
        expect(community_chat_recap.summarized_message_count).to eq(0)
        expect(community_chat_recap.input_token_count).to eq(0)
        expect(community_chat_recap.output_token_count).to eq(0)
      end
    end

    context "when generating weekly recap" do
      let(:from_date) { Date.yesterday.beginning_of_day - 6.days }

      let!(:daily_recap1) { create(:community_chat_recap, :finished, community:, community_chat_recap_run: create(:community_chat_recap_run, from_date: (from_date + 3.day).beginning_of_day, to_date: (from_date + 4.days).end_of_day), summary: "<ul><li>Creator share a new version of the app.</li><li>A customer asked about when the app will be released on Android.</li><li>Creator shared the release date.</li></ul>", summarized_message_count: 12, status: "finished") }
      let!(:daily_recap2) { create(:community_chat_recap, :finished, community:, community_chat_recap_run: create(:community_chat_recap_run, from_date: (from_date + 5.day).beginning_of_day, to_date: (from_date + 6.days).end_of_day), summary: "<ul><li>Customers discussed about various issues with the product.</li><li>Creator confirmed that the issue is known and will be fixed in the next version.</li></ul>", summarized_message_count: 45, status: "finished") }

      let(:weekly_recap_run) { create(:community_chat_recap_run, :weekly, from_date:, to_date: (from_date + 6.days).end_of_day) }
      let(:weekly_recap) { create(:community_chat_recap, community:, community_chat_recap_run: weekly_recap_run) }

      it "generates a weekly summary from daily recaps" do
        VCR.use_cassette("community_chat_recap_generator/weekly_summary") do
          described_class.new(community_chat_recap: weekly_recap).process
        end

        expect(weekly_recap.reload).to be_status_finished
        expect(weekly_recap.summary).to match(/<ul>.*?<\/ul>/m)
        expect(weekly_recap.summary.scan("</li>").count).to eq(2)
        expect(weekly_recap.summary).to include("<li>The **new version of the app** was shared by the creator, along with a confirmed **release date** for Android.</li>")
        expect(weekly_recap.summary).to include("<li>Customers raised concerns regarding various **product issues**, which the creator acknowledged and assured would be addressed in the **next version**.</li>")
        expect(weekly_recap.summarized_message_count).to eq(57)
        expect(weekly_recap.input_token_count).to eq(255)
        expect(weekly_recap.output_token_count).to eq(67)
      end

      it "handles no daily recaps in the given period" do
        daily_recap1.update!(summary: "", summarized_message_count: 0)
        daily_recap2.update!(summary: "", summarized_message_count: 0)

        described_class.new(community_chat_recap: weekly_recap).process

        expect(weekly_recap.reload).to be_status_finished
        expect(weekly_recap.summary).to be_empty
        expect(weekly_recap.summarized_message_count).to eq(0)
        expect(weekly_recap.input_token_count).to eq(0)
        expect(weekly_recap.output_token_count).to eq(0)
      end
    end

    context "when OpenAI API fails" do
      let(:community) { create(:community, seller:) }
      let!(:community_chat_message) { create(:community_chat_message, community:, created_at: Date.yesterday.beginning_of_day + 1.hour) }
      let(:recap_run) { create(:community_chat_recap_run, from_date: Date.yesterday.beginning_of_day, to_date: Date.yesterday.end_of_day) }
      let(:community_chat_recap) { create(:community_chat_recap, community:, community_chat_recap_run: recap_run) }

      before do
        allow(OpenAI::Client).to receive(:new).and_raise(StandardError.new("API Error"))
      end

      it "retries the operation" do
        expect do
          expect do
            described_class.new(community_chat_recap:).process
          end.to raise_error(StandardError)
        end.not_to change { community_chat_recap.reload }
      end
    end
  end
end
