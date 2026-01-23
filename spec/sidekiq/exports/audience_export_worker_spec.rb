# frozen_string_literal: true

require "spec_helper"

describe Exports::AudienceExportWorker do
  describe "#perform" do
    let(:seller) { create(:user) }
    let(:audience_options) { { "followers" => true } }
    let(:recipient) { create(:user) }

    before do
      ActionMailer::Base.deliveries.clear
    end

    describe "sync export path (small audience)" do
      it "sends email to seller when it is also the recipient" do
        expect(ContactingCreatorMailer).to receive(:subscribers_data).and_call_original
        described_class.new.perform(seller.id, seller.id, audience_options)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq([seller.email])
      end

      it "sends email to recipient" do
        expect(ContactingCreatorMailer).to receive(:subscribers_data).and_call_original
        described_class.new.perform(seller.id, recipient.id, audience_options)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq([recipient.email])
      end

      it "does not create AudienceExport record for small audiences" do
        create(:audience_member, seller: seller, email: "follower@example.com",
          details: { "follower" => { "id" => 1, "created_at" => Time.current.iso8601 } })

        expect {
          described_class.new.perform(seller.id, recipient.id, audience_options)
        }.not_to change { AudienceExport.count }
      end
    end

    describe "async export path (large audience)" do
      before do
        stub_const("#{described_class}::SYNC_EXPORT_THRESHOLD", 2)
        3.times do |i|
          create(:audience_member, seller: seller, email: "follower#{i}@example.com",
            details: { "follower" => { "id" => i, "created_at" => Time.current.iso8601 } })
        end
      end

      it "creates AudienceExport record" do
        expect {
          described_class.new.perform(seller.id, recipient.id, audience_options)
        }.to change { AudienceExport.count }.by(1)

        export = AudienceExport.last
        expect(export.seller).to eq(seller)
        expect(export.recipient).to eq(recipient)
        expect(export.followers).to eq(true)
        expect(export.customers).to eq(false)
        expect(export.affiliates).to eq(false)
      end

      it "enqueues CreateAndEnqueueChunksJob" do
        described_class.new.perform(seller.id, recipient.id, audience_options)

        export = AudienceExport.last
        expect(Exports::Audience::CreateAndEnqueueChunksJob).to have_enqueued_sidekiq_job(export.id)
      end

      it "does not send email synchronously" do
        described_class.new.perform(seller.id, recipient.id, audience_options)

        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    describe "threshold boundary" do
      before do
        stub_const("#{described_class}::SYNC_EXPORT_THRESHOLD", 2)
      end

      it "uses sync export at exactly threshold" do
        2.times do |i|
          create(:audience_member, seller: seller, email: "follower#{i}@example.com",
            details: { "follower" => { "id" => i, "created_at" => Time.current.iso8601 } })
        end

        expect {
          described_class.new.perform(seller.id, recipient.id, audience_options)
        }.not_to change { AudienceExport.count }

        expect(ActionMailer::Base.deliveries.count).to eq(1)
      end

      it "uses async export at threshold + 1" do
        3.times do |i|
          create(:audience_member, seller: seller, email: "follower#{i}@example.com",
            details: { "follower" => { "id" => i, "created_at" => Time.current.iso8601 } })
        end

        expect {
          described_class.new.perform(seller.id, recipient.id, audience_options)
        }.to change { AudienceExport.count }.by(1)

        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end
  end
end
