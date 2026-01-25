# frozen_string_literal: true

require "spec_helper"

describe "Audience Export Integration", type: :integration do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }
  let!(:follower_1) { create(:active_follower, user: seller, email: "follower1@test.com", created_at: 1.day.ago) }
  let!(:follower_2) { create(:active_follower, user: seller, email: "follower2@test.com", created_at: 2.days.ago) }
  let!(:follower_3) { create(:active_follower, user: seller, email: "follower3@test.com", created_at: 3.days.ago) }
  let(:audience_options) { { followers: true } }
  let(:mock_mail) { double("mail", deliver_now: true) }

  before do
    # Use small chunk size to test chunking behavior
    stub_const("Exports::Audience::CreateAndEnqueueChunksWorker::MAX_MEMBERS_PER_CHUNK", 2)
    # Stub mailer to avoid Shakapacker/webpack dependency
    allow(ContactingCreatorMailer).to receive(:subscribers_data).and_return(mock_mail)
  end

  it "exports audience data through the full worker chain" do
    # Step 1: Initial worker creates export and enqueues chunk creation
    Exports::AudienceExportWorker.new.perform(seller.id, recipient.id, audience_options)

    export = AudienceExport.last
    expect(export).to be_present
    expect(export.seller).to eq(seller)
    expect(export.recipient).to eq(recipient)

    # Step 2: CreateAndEnqueueChunksWorker creates chunks
    Exports::Audience::CreateAndEnqueueChunksWorker.new.perform(export.id)
    export.reload

    expect(export.chunks.count).to eq(2) # 3 followers / 2 per chunk = 2 chunks
    chunk_ids = export.chunks.order(:id).pluck(:id)

    # Step 3: ProcessChunkWorker processes each chunk
    Exports::Audience::ProcessChunkWorker.new.perform(chunk_ids.first)
    export.reload
    expect(export.chunks.where(processed: true).count).to eq(1)

    # Processing the last chunk should trigger compile
    Exports::Audience::ProcessChunkWorker.new.perform(chunk_ids.second)
    export.reload
    expect(export.chunks.where(processed: true).count).to eq(2)

    # Verify all chunks have audience data with correct emails
    all_emails = export.chunks.flat_map { |c| c.audience_data.map(&:first) }
    expect(all_emails).to contain_exactly("follower1@test.com", "follower2@test.com", "follower3@test.com")

    # Step 4: CompileChunksWorker compiles and sends email
    expect(ContactingCreatorMailer).to receive(:subscribers_data).with(
      recipient: recipient,
      tempfile: anything,
      filename: anything
    ).and_return(mock_mail)

    Exports::Audience::CompileChunksWorker.new.perform(export.id)

    # Verify cleanup
    expect(AudienceExport.count).to eq(0)
    expect(AudienceExportChunk.count).to eq(0)
  end

  context "with multiple audience types" do
    let(:product) { create(:product, user: seller, name: "Product 1") }
    let!(:customer) { create(:free_purchase, seller:, link: product, created_at: 5.days.ago) }
    let(:audience_options) { { followers: true, customers: true } }

    it "includes all selected audience types in export" do
      # Run full chain
      Exports::AudienceExportWorker.new.perform(seller.id, recipient.id, audience_options)
      export = AudienceExport.last

      Exports::Audience::CreateAndEnqueueChunksWorker.new.perform(export.id)
      export.reload

      export.chunks.each do |chunk|
        Exports::Audience::ProcessChunkWorker.new.perform(chunk.id)
      end

      # Verify all chunks have audience data
      all_emails = export.chunks.reload.flat_map { |c| c.audience_data.map(&:first) }
      # 4 audience members: 3 followers + 1 customer
      expect(all_emails.size).to eq(4)

      expect(ContactingCreatorMailer).to receive(:subscribers_data).with(
        recipient: recipient,
        tempfile: anything,
        filename: anything
      ).and_return(mock_mail)

      Exports::Audience::CompileChunksWorker.new.perform(export.id)

      # Verify cleanup
      expect(AudienceExport.count).to eq(0)
      expect(AudienceExportChunk.count).to eq(0)
    end
  end
end
