# frozen_string_literal: true

require "spec_helper"

describe GdprVersionRedactor, :versioning do
  def snapshots(record)
    record.versions.reload.map { [PaperTrail.serializer.load(_1.object.presence || "{}"), PaperTrail.serializer.load(_1.object_changes.presence || "{}")] }
  end

  it "blanks the given attributes in the item's versions and keeps every other attribute" do
    user = create(:user, name: "Old name", bio: "Old bio")
    user.update!(name: "New name", bio: "New bio")
    other_user = create(:user, name: "Other old name")
    other_user.update!(name: "Other new name")

    redacted = described_class.redact!(item_type: "User", item_ids: user.id, attributes: [:name])

    expect(redacted).to eq(2)
    create_snapshot, update_snapshot = snapshots(user)
    expect(create_snapshot.last["name"]).to eq([nil, nil])
    expect(update_snapshot.first).to include("name" => nil, "bio" => "Old bio")
    expect(update_snapshot.last).to include("name" => [nil, nil], "bio" => ["Old bio", "New bio"])
    expect(snapshots(other_user).last.last["name"]).to eq(["Other old name", "Other new name"])
  end

  it "rewrites nothing when no version holds the attributes" do
    user = create(:user)
    user.update!(bio: "New bio")

    expect do
      expect(described_class.redact!(item_type: "User", item_ids: user.id, attributes: [:kindle_email])).to eq(0)
    end.not_to change { user.versions.reload.map(&:object_changes) }
  end
end
