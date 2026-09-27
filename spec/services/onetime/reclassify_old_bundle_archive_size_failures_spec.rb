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

    expect(described_class.process).to eq(considered: 1, reclassified: 1, skipped: 0)

    expect(archive.reload).to be_too_large
    expect(archive.updated_at).to be_within(1.second).of(before_cutoff)
  end

  it "lets a bundle whose old size failures used up its retry budget build a ZIP again" do
    files = bundle_files(300.megabytes, 300.megabytes)
    purchase = create(:purchase, link: bundle)
    purchase.create_artifacts_and_send_receipt!
    UrlRedirect::BUNDLE_ARCHIVE_MAX_FAILED_ATTEMPTS.times { failed_archive(bundle, files) }
    archive_count = -> { bundle.product_files_archives.alive.entity_archives.count }
    travel_to(before_cutoff + UrlRedirect::BUNDLE_ARCHIVE_MAX_TOO_LARGE_RETRY_COOLDOWN + 1.hour)

    expect { UrlRedirect.find(purchase.url_redirect.id).bundle_archive }.not_to change { archive_count.call }

    described_class.process

    expect { UrlRedirect.find(purchase.url_redirect.id).bundle_archive }.to change { archive_count.call }.by(1)
  end

  it "reads an unrecorded size from S3, as the old worker did" do
    large = failed_archive(bundle, bundle_files(1.megabyte, nil))
    small = failed_archive(bundle, bundle_files(1.megabyte, nil))
    missing = failed_archive(bundle, bundle_files(1.megabyte, nil))
    forbidden = failed_archive(bundle, bundle_files(1.megabyte, nil))
    s3_sizes = { large => 600.megabytes, small => 2.megabytes }
    s3_errors = { missing => Aws::S3::Errors::NotFound.new(nil, "missing"), forbidden => Aws::S3::Errors::Forbidden.new(nil, "denied") }
    s3_objects = [large, small, missing, forbidden].to_h do |archive|
      file = archive.product_files.find { _1.size.nil? }
      object = instance_double(Aws::S3::Object)
      if s3_sizes.key?(archive)
        allow(object).to receive(:content_length).and_return(s3_sizes[archive])
      else
        allow(object).to receive(:content_length).and_raise(s3_errors.fetch(archive))
      end
      [file.id, object]
    end
    allow_any_instance_of(ProductFile).to receive(:s3_object) { |file| s3_objects.fetch(file.id) }

    expect(described_class.process).to eq(considered: 4, reclassified: 1, skipped: 1)

    expect([large, small, missing, forbidden].map { _1.reload.product_files_archive_state }).to eq(%w[too_large failed failed failed])
  end

  it "leaves failures the old limit cannot explain" do
    small = failed_archive(bundle, bundle_files(1.megabyte, 2.megabytes))
    recent = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes), failed_at: described_class::FAILED_BEFORE + 1.minute)
    product = create(:product)
    not_a_bundle = failed_archive(product, [create(:product_file, link: product, size: 600.megabytes)])
    link_only = failed_archive(bundle, [create(:product_file, link: members.first, size: 1.megabyte),
                                        create(:product_file, link: members.last, filetype: "link", url: "https://example.com", size: nil)])
    deleted = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes)).tap { _1.update_columns(deleted_at: before_cutoff) }
    folder = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes)).tap { _1.update_columns(folder_id: "folder") }

    described_class.process

    expect([small, recent, not_a_bundle, link_only, deleted, folder].map { _1.reload.product_files_archive_state }).to all(eq("failed"))
  end

  it "changes nothing on a dry run and nothing more on a rerun" do
    archive = failed_archive(bundle, bundle_files(300.megabytes, 300.megabytes))

    expect(described_class.process(dry_run: true)).to eq(considered: 1, reclassified: 1, skipped: 0)
    expect(archive.reload).to be_failed

    described_class.process
    expect(described_class.process).to eq(considered: 0, reclassified: 0, skipped: 0)
    expect(archive.reload).to be_too_large
  end
end
