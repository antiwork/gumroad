# frozen_string_literal: true

require "spec_helper"

describe EmailSuppressionManager, :vcr do
  let(:email) { "sam@example.com" }

  describe "#detailed_status" do
    def stub_list(list, body)
      allow_any_instance_of(SendGrid::Client).to receive_message_chain(list, :_, :get, :parsed_body).and_return(body)
    end

    it "returns an empty bucket for every list when nothing is suppressed" do
      [:bounces, :blocks, :spam_reports, :invalid_emails].each { |list| stub_list(list, []) }

      result = described_class.new(email).detailed_status

      expect(result.keys).to match_array([:bounces, :blocks, :spam_reports, :invalid_emails])
      expect(result.values).to all(eq([]))
    end

    it "returns subuser-tagged entries for each suppression hit" do
      bounce_entry = { created: 1683811050, email:, reason: "550 5.1.1 mailbox does not exist", status: "5.1.1" }
      block_entry  = { created: 1683811060, email:, reason: "blocked by recipient mailserver", status: "5.7.1" }
      stub_list(:bounces, [bounce_entry])
      stub_list(:blocks, [block_entry])
      stub_list(:spam_reports, [])
      stub_list(:invalid_emails, [])

      result = described_class.new(email).detailed_status

      expect(result[:bounces]).to be_present
      expect(result[:bounces].first).to include(reason: "550 5.1.1 mailbox does not exist", subuser: :gumroad)
      expect(result[:bounces].first[:created_at]).to eq(Time.zone.at(1683811050).iso8601)
      expect(result[:blocks]).to be_present
    end

    it "swallows and reports parsing errors per list without aborting the scan" do
      stub_list(:bounces, "garbage")
      stub_list(:blocks, [])
      stub_list(:spam_reports, [])
      stub_list(:invalid_emails, [])
      expect(ErrorNotifier).to receive(:notify).at_least(:once)

      expect { described_class.new(email).detailed_status }.not_to raise_error
    end
  end

  describe "#remove_from_lists" do
    it "deletes only the requested lists across every subuser" do
      list_chain = double(_: double(delete: double(status_code: 204)))
      allow_any_instance_of(SendGrid::Client).to receive(:bounces).and_return(list_chain)

      result = described_class.new(email).remove_from_lists([:bounces])

      expect(result.keys).to eq([:bounces])
      expect(result[:bounces]).to match_array([:gumroad, :followers, :creators, :customers_level_1, :customers_level_2])
    end

    it "skips subusers whose deletion call returns a non-success status" do
      list_chain = double(_: double(delete: double(status_code: 404)))
      allow_any_instance_of(SendGrid::Client).to receive(:bounces).and_return(list_chain)

      result = described_class.new(email).remove_from_lists([:bounces])

      expect(result[:bounces]).to eq([])
    end
  end
end
