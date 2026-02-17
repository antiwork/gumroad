# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillAudienceMembersElasticsearchIndex do
  it "enqueues index jobs for all audience members" do
    seller = create(:user)
    member1 = create(:audience_member, seller:, purchases: [{ "product_id" => 1 }])
    member2 = create(:audience_member, seller:, follower: {})

    ElasticsearchIndexerWorker.jobs.clear

    expect do
      described_class.new.process
    end.to change { ElasticsearchIndexerWorker.jobs.count }.by(2)

    expect(ElasticsearchIndexerWorker.jobs).to include(
      hash_including("args" => ["index", hash_including("record_id" => member1.id, "class_name" => "AudienceMember")]),
      hash_including("args" => ["index", hash_including("record_id" => member2.id, "class_name" => "AudienceMember")])
    )
  end

  it "respects start_id and end_id for chunked processing" do
    seller = create(:user)
    create(:audience_member, seller:, purchases: [{ "product_id" => 1 }])
    member2 = create(:audience_member, seller:, follower: {})
    create(:audience_member, seller:, affiliates: [{}])

    ElasticsearchIndexerWorker.jobs.clear

    described_class.new(start_id: member2.id, end_id: member2.id).process

    expect(ElasticsearchIndexerWorker.jobs.count).to eq(1)
    expect(ElasticsearchIndexerWorker.jobs.first["args"].last["record_id"]).to eq(member2.id)
  end
end
