# frozen_string_literal: true

require "spec_helper"

# GenerateAvatarVariantJob is enqueued as soon as the avatar commits, so a worker can run it before the
# replica has the new attachment. A miss is silent: the job finishes and nothing retries the upload.
describe "mysql2 proxy avatar variant routing" do
  include_context "real mysql2 proxy pools"

  def expect_primary_reads(reads, *tables)
    tables.each do |table|
      relevant = reads.select { |sql, _| sql.include?("`#{table}`") }
      expect(relevant).not_to be_empty
      expect(relevant.map(&:last).uniq).to eq(["primary"])
    end
  end

  def current_avatar_resized?(user)
    primary_setup do
      blob = user.reload.avatar.blob
      variant = blob.variant_records.find_by(variation_digest: blob.variant(User::AVATAR_VARIANT_TRANSFORMATIONS).variation.digest)
      variant.present? && variant.image.attached?
    end
  end

  it "resizes the avatar of a user the replica has not received yet" do
    user = primary_setup { create(:user, :with_avatar) }
    expect(serving_pool).to eq("replica")

    reads = record_serving_reads { GenerateAvatarVariantJob.new.perform(user.id) }

    expect(current_avatar_resized?(user)).to be(true)
    expect_primary_reads(reads, "users", "active_storage_attachments", "active_storage_blobs", "active_storage_variant_records")
    expect(serving_pool).to eq("replica")
  end

  it "resizes the new avatar while the replica still has the previous one" do
    user = primary_setup { create(:user, :with_avatar) }
    previous_blob = user.avatar.blob
    [user, user.avatar.attachment, previous_blob].each { replicate_record(_1) }
    primary_setup do
      user.avatar.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "new.png")
    end
    expect(primary_setup { user.reload.avatar.blob.id }).not_to eq(previous_blob.id)
    expect(serving_pool).to eq("replica")

    reads = record_serving_reads { GenerateAvatarVariantJob.new.perform(user.id) }

    expect(current_avatar_resized?(user)).to be(true)
    expect_primary_reads(reads, "users", "active_storage_attachments", "active_storage_blobs", "active_storage_variant_records")
    expect(serving_pool).to eq("replica")
  end
end
