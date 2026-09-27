# frozen_string_literal: true

require "spec_helper"

describe Onetime::ReclassifyOldBundleArchiveSizeFailures do
  let(:bundle) { create(:product, :bundle) }
  let(:members) { bundle.bundle_products.map(&:product) }
  let(:before_cutoff) { described_class::FAILED_BEFORE - 1.day }

  def failed_archive(owner, files, failed_at: before_cutoff)
    archive = owner.product_files_archives.create!(product_files: files)
    archive.mark_failed!
    archive.update_columns(updated_at: failed_at)
    archive
  end

  def bundle_files(*sizes)
    members.zip(sizes).map { |product, size| create(:product_file, link: product, size:) }
  end

  it "marks an old failed bundle archive over the old limit too large, keeping its failure time" do
    archive = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes))

    expect(described_class.process).to eq(considered: 1, reclassified: 1)

    expect(archive.reload).to be_too_large
    expect(archive.updated_at).to be_within(1.second).of(before_cutoff)
  end

  it "marks an old failed bundle archive with an unrecorded S3 size too large" do
    archive = failed_archive(bundle, bundle_files(1.megabyte, nil))

    described_class.process

    expect(archive.reload).to be_too_large
  end

  it "leaves failures the old limit cannot explain" do
    small = failed_archive(bundle, bundle_files(1.megabyte, 2.megabytes))
    recent = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes), failed_at: described_class::FAILED_BEFORE + 1.minute)
    product = create(:product)
    not_a_bundle = failed_archive(product, [create(:product_file, link: product, size: 600.megabytes)])
    link_only = failed_archive(bundle, [create(:product_file, link: members.first, size: 1.megabyte),
                                        create(:product_file, link: members.last, filetype: "link", url: "https://example.com", size: nil)])

    described_class.process

    expect([small, recent, not_a_bundle, link_only].map { _1.reload.product_files_archive_state }).to all(eq("failed"))
  end

  it "changes nothing on a dry run and nothing more on a rerun" do
    archive = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes))

    expect(described_class.process(dry_run: true)).to eq(considered: 1, reclassified: 1)
    expect(archive.reload).to be_failed

    described_class.process
    expect(described_class.process).to eq(considered: 0, reclassified: 0)
    expect(archive.reload).to be_too_large
  end
end
