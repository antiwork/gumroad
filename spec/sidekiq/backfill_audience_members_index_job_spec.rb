# frozen_string_literal: true

require "spec_helper"

describe BackfillAudienceMembersIndexJob do
  before do
    recreate_model_index(AudienceMember)
  end

  it "indexes only members within the id range" do
    members = create_list(:audience_member, 3)

    described_class.new.perform(members.first.id, members.second.id)
    AudienceMember.__elasticsearch__.refresh_index!

    expect(EsClient.exists?(index: AudienceMember.index_name, id: members.first.id)).to eq(true)
    expect(EsClient.exists?(index: AudienceMember.index_name, id: members.second.id)).to eq(true)
    expect(EsClient.exists?(index: AudienceMember.index_name, id: members.third.id)).to eq(false)
    document = EsClient.get(index: AudienceMember.index_name, id: members.first.id)["_source"]
    expect(document).to eq(members.first.as_indexed_json)
  end

  it "skips the range when the pause flag is active" do
    member = create(:audience_member)
    Feature.activate(:pause_audience_members_index_backfill)

    described_class.new.perform(member.id, member.id)
    AudienceMember.__elasticsearch__.refresh_index!

    expect(EsClient.exists?(index: AudienceMember.index_name, id: member.id)).to eq(false)
  ensure
    Feature.deactivate(:pause_audience_members_index_backfill)
  end

  it "scopes the range to the seller when seller_id is given" do
    seller = create(:user)
    member = create(:audience_member, seller:)
    other_member = create(:audience_member)
    range = [member.id, other_member.id].minmax

    described_class.new.perform(range.first, range.last, seller.id)
    AudienceMember.__elasticsearch__.refresh_index!

    expect(EsClient.exists?(index: AudienceMember.index_name, id: member.id)).to eq(true)
    expect(EsClient.exists?(index: AudienceMember.index_name, id: other_member.id)).to eq(false)
  end
end
