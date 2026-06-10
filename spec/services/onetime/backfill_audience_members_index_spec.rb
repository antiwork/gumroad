# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillAudienceMembersIndex do
  before do
    recreate_model_index(AudienceMember)
    $redis.del(described_class::REDIS_CURSOR_KEY)
    $redis.del(described_class::REDIS_FAILED_IDS_KEY)
  end

  it "raises when the index does not exist" do
    AudienceMember.__elasticsearch__.delete_index!

    expect do
      described_class.process
    end.to raise_error(/#{AudienceMember.index_name} index is missing/)
  end

  it "bulk indexes all audience members in batches and tracks the cursor" do
    members = create_list(:audience_member, 3)

    described_class.process(batch_size: 2)
    AudienceMember.__elasticsearch__.refresh_index!

    members.each do |member|
      expect(EsClient.exists?(index: AudienceMember.index_name, id: member.id)).to eq(true)
    end
    document = EsClient.get(index: AudienceMember.index_name, id: members.first.id)["_source"]
    expect(document).to eq(members.first.as_indexed_json)
    expect($redis.get(described_class::REDIS_CURSOR_KEY).to_i).to eq(members.last.id)
  end

  it "resumes from the stored cursor" do
    members = create_list(:audience_member, 3)
    $redis.set(described_class::REDIS_CURSOR_KEY, members.second.id)

    described_class.process
    AudienceMember.__elasticsearch__.refresh_index!

    expect(EsClient.exists?(index: AudienceMember.index_name, id: members.first.id)).to eq(false)
    expect(EsClient.exists?(index: AudienceMember.index_name, id: members.second.id)).to eq(false)
    expect(EsClient.exists?(index: AudienceMember.index_name, id: members.last.id)).to eq(true)
  end

  it "removes documents whose members no longer exist" do
    member = create(:audience_member)
    deleted_member = create(:audience_member)

    described_class.process
    AudienceMember.__elasticsearch__.refresh_index!
    expect(EsClient.exists?(index: AudienceMember.index_name, id: deleted_member.id)).to eq(true)

    deleted_member.delete
    described_class.process
    AudienceMember.__elasticsearch__.refresh_index!

    expect(EsClient.exists?(index: AudienceMember.index_name, id: member.id)).to eq(true)
    expect(EsClient.exists?(index: AudienceMember.index_name, id: deleted_member.id)).to eq(false)
  end

  it "records members that fail to index without blocking the rest of the backfill" do
    member = create(:audience_member)
    other_member = create(:audience_member)
    allow(EsClient).to receive(:bulk).and_wrap_original do |original, *args, **kwargs|
      response = original.call(*args, **kwargs)
      response["errors"] = true
      response["items"] = [{ "index" => { "_id" => member.id.to_s, "error" => { "type" => "mapper_parsing_exception" } } }]
      response
    end

    described_class.process(batch_size: 1)

    expect($redis.smembers(described_class::REDIS_FAILED_IDS_KEY)).to eq([member.id.to_s])
    expect($redis.get(described_class::REDIS_CURSOR_KEY).to_i).to eq(other_member.id)
  end

  context "when scoped to a seller" do
    let(:seller) { create(:user) }
    let(:cursor_key) { "#{described_class::REDIS_CURSOR_KEY}_seller_#{seller.id}" }

    before do
      $redis.del(cursor_key)
    end

    it "indexes only that seller's members and tracks a per-seller cursor" do
      seller_members = create_list(:audience_member, 2, seller:)
      other_member = create(:audience_member)

      described_class.process(batch_size: 1, seller_id: seller.id)
      AudienceMember.__elasticsearch__.refresh_index!

      seller_members.each do |member|
        expect(EsClient.exists?(index: AudienceMember.index_name, id: member.id)).to eq(true)
      end
      expect(EsClient.exists?(index: AudienceMember.index_name, id: other_member.id)).to eq(false)
      expect($redis.get(cursor_key).to_i).to eq(seller_members.last.id)
      expect($redis.get(described_class::REDIS_CURSOR_KEY)).to be_nil
    end

    it "removes only that seller's stale documents" do
      stale_seller_member = create(:audience_member, seller:)
      other_member = create(:audience_member)

      described_class.process
      AudienceMember.__elasticsearch__.refresh_index!
      stale_seller_member.delete
      other_member.delete

      described_class.process(seller_id: seller.id)
      AudienceMember.__elasticsearch__.refresh_index!

      expect(EsClient.exists?(index: AudienceMember.index_name, id: stale_seller_member.id)).to eq(false)
      expect(EsClient.exists?(index: AudienceMember.index_name, id: other_member.id)).to eq(true)
    end

    it "keeps suppressing indexer 404s after the run" do
      create(:audience_member, seller:)

      described_class.process(seller_id: seller.id)

      expect($redis.smembers(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices)).to include(AudienceMember.index_name)
    ensure
      $redis.srem(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices, AudienceMember.index_name)
    end
  end

  it "suppresses indexer 404s only while the backfill is running" do
    create(:audience_member)
    ignore_set_during_run = nil
    allow_any_instance_of(described_class).to receive(:delete_stale_documents) do
      ignore_set_during_run = $redis.smembers(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices)
    end

    described_class.process

    expect(ignore_set_during_run).to include(AudienceMember.index_name)
    expect($redis.smembers(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices)).not_to include(AudienceMember.index_name)
  end
end
