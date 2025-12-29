# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::CompileChunksJob do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }
  let(:export) { create(:audience_export, seller: seller, recipient: recipient) }

  before do
    ActionMailer::Base.deliveries.clear
  end

  describe "#perform" do
    context "with processed chunks" do
      before do
        create(:audience_export_chunk, export: export, processed: true,
          members_data: [["user1@example.com", "2024-01-01 00:00:00"], ["user2@example.com", "2024-01-02 00:00:00"]])
        create(:audience_export_chunk, export: export, processed: true,
          members_data: [["user3@example.com", "2024-01-03 00:00:00"]])
      end

      it "sends email with CSV containing all members" do
        described_class.new.perform(export.id)

        expect(ActionMailer::Base.deliveries.count).to eq(1)
        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq([recipient.email])
      end

      it "generates CSV with correct content" do
        described_class.new.perform(export.id)

        mail = ActionMailer::Base.deliveries.last
        attachment = mail.attachments.first
        csv_content = CSV.parse(attachment.read)

        expect(csv_content.size).to eq(4)
        expect(csv_content[0]).to eq(["Subscriber Email", "Subscribed Time"])
        expect(csv_content[1]).to eq(["user1@example.com", "2024-01-01 00:00:00"])
        expect(csv_content[2]).to eq(["user2@example.com", "2024-01-02 00:00:00"])
        expect(csv_content[3]).to eq(["user3@example.com", "2024-01-03 00:00:00"])
      end

      it "generates filename with seller username and timestamp" do
        described_class.new.perform(export.id)

        mail = ActionMailer::Base.deliveries.last
        attachment = mail.attachments.first
        expect(attachment.filename).to start_with("Subscribers-#{seller.username}_")
        expect(attachment.filename).to end_with(".csv")
      end

      it "deletes chunks after completion" do
        expect(AudienceExportChunk.count).to eq(2)

        described_class.new.perform(export.id)

        expect(AudienceExportChunk.count).to eq(0)
      end

      it "deletes export after completion" do
        expect(AudienceExport.count).to eq(1)

        described_class.new.perform(export.id)

        expect(AudienceExport.count).to eq(0)
      end
    end

    context "with empty chunks" do
      it "sends email with headers-only CSV" do
        described_class.new.perform(export.id)

        mail = ActionMailer::Base.deliveries.last
        attachment = mail.attachments.first
        csv_content = CSV.parse(attachment.read)

        expect(csv_content.size).to eq(1)
        expect(csv_content[0]).to eq(["Subscriber Email", "Subscribed Time"])
      end
    end
  end
end
