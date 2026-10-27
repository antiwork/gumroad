# frozen_string_literal: true

require "spec_helper"

describe PartnerMigrationImportJob do
  let(:partner_application) { create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api") }
  let(:seller) { create(:user) }
  let(:image) { File.binread(Rails.root.join("spec/support/fixtures/smilie.png")) }
  let(:remote_files) do
    {
      "https://files.example.com/pack.zip" => ["application/zip", "zip bytes"],
      "https://files.example.com/cover.png" => ["image/png", image],
      "https://files.example.com/thumb.png" => ["image/png", image],
      "https://files.example.com/wide.png" => ["image/png", File.binread(Rails.root.join("spec/support/fixtures/lemons-640x362.png"))],
    }
  end
  let(:product_attributes) do
    {
      name: "Texture Pack",
      description: "<p>Forty textures.</p>",
      price: 1500,
      tags: ["textures"],
      files: [{ url: "https://files.example.com/pack.zip", display_name: "Pack" }],
      covers: [{ url: "https://files.example.com/cover.png" }],
      thumbnail_url: "https://files.example.com/thumb.png",
      variant_categories: [{ title: "License", variants: [{ name: "Standard" }, { name: "Commercial", price_difference_cents: 3000 }] }],
    }
  end

  def create_claimed_migration(products)
    normalized, error = PartnerMigration.normalize_products(products)
    raise error if error

    migration, _code = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products: normalized)
    migration.update!(status: PartnerMigration::STATUS_CLAIMED, user: seller)
    migration
  end

  before do
    allow(SsrfFilter).to receive(:get) do |url, &block|
      content_type, body = remote_files[url.to_s]
      response = body ? Net::HTTPOK.new("1.1", "200", "") : Net::HTTPNotFound.new("1.1", "404", "")
      response["content-type"] = content_type
      allow(response).to receive(:read_body).and_yield(body.to_s)
      allow(response).to receive(:body).and_return(body.to_s)
      block&.call(response)
      response
    end
  end

  it "imports each product as a draft with its variants, files, cover, and thumbnail" do
    migration = create_claimed_migration([product_attributes])

    described_class.new.perform(migration.id)

    product = seller.links.sole
    expect(product).to have_attributes(name: "Texture Pack", description: "<p>Forty textures.</p>", price_cents: 1500, draft: true, purchase_disabled_at: be_present)
    expect(product.alive?).to be(false)
    expect(product.tags.pluck(:name)).to eq(["textures"])
    expect(product.variant_categories.sole.title).to eq("License")
    expect(product.variant_categories.sole.variants.map { [_1.name, _1.price_difference_cents] }).to eq([["Standard", 0], ["Commercial", 3000]])
    product_file = product.alive_product_files.sole
    expect(product_file).to have_attributes(display_name: "Pack")
    expect(product_file.url).to start_with("#{S3_BASE_URL}attachments/#{seller.external_id}/")
    expect(product.has_product_level_rich_content?).to be(true)
    expect(product.alive_rich_contents.sole.description).to match([include("type" => "fileEmbed", "attrs" => include("id" => product_file.external_id))])
    expect(product.asset_previews.alive.count).to eq(1)
    expect(product.thumbnail).to be_present
    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_COMPLETED, completed_at: be_present, results: { "0" => { "product_id" => product.external_id } })
    expect(PartnerMigrationNotificationJob).to have_enqueued_sidekiq_job(migration.id)
  end

  it "records a product that cannot be imported and continues with the others" do
    migration = create_claimed_migration([
                                           product_attributes.merge(name: "Missing file", files: [{ url: "https://files.example.com/missing.zip" }]),
                                           { name: "Brush Set", price: 500 },
                                         ])

    described_class.new.perform(migration.id)

    expect(seller.links.pluck(:name)).to eq(["Brush Set"])
    expect(migration.reload.results).to eq(
      "0" => { "error" => "The file download failed with HTTP 404." },
      "1" => { "product_id" => seller.links.sole.external_id },
    )
    expect(migration.status).to eq(PartnerMigration::STATUS_FAILED)
  end

  it "imports a catalog above the daily editor quota", :enforce_product_creation_limit do
    migration = create_claimed_migration(Array.new(11) { |index| { name: "Asset #{index}", price: 500 } })

    described_class.new.perform(migration.id)

    expect(seller.links.count).to eq(11)
    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_COMPLETED)
    expect(migration.results.values).to all(include("product_id"))
  end

  it "keeps the product and returns a warning when a cover cannot be imported" do
    migration = create_claimed_migration([product_attributes.merge(covers: [{ url: "https://files.example.com/missing.png" }])])

    described_class.new.perform(migration.id)

    product = seller.links.sole
    expect(product.asset_previews.alive.count).to eq(0)
    expect(migration.reload.results["0"]).to include("product_id" => product.external_id, "warnings" => [a_string_starting_with("Cover https://files.example.com/missing.png was not imported")])
  end

  it "rejects a cover larger than the cover size limit" do
    stub_const("AssetPreview::MAX_IMAGE_FILE_SIZE", 10)
    migration = create_claimed_migration([product_attributes])

    described_class.new.perform(migration.id)

    expect(seller.links.sole.asset_previews.alive.count).to eq(0)
    expect(migration.reload.results["0"]["warnings"]).to include(a_string_starting_with("Cover https://files.example.com/cover.png was not imported: The file is larger than"))
  end

  it "deletes the uploaded cover and thumbnail when their analysis fails" do
    allow_any_instance_of(ActiveStorage::Attached::One).to receive(:analyze).and_raise(Aws::S3::Errors::ServiceError.new(nil, "S3 is down"))
    allow_any_instance_of(AssetPreview).to receive(:analyze_file).and_raise(Aws::S3::Errors::ServiceError.new(nil, "S3 is down"))
    migration = create_claimed_migration([product_attributes.merge(files: [])])

    expect { described_class.new.perform(migration.id) }.not_to change { ActiveStorage::Blob.count }

    expect(migration.reload.results["0"]["warnings"].size).to eq(2)
  end

  it "stops a thumbnail download that runs past the time limit" do
    stub_const("PartnerMigration::RemoteFileTransfer::MAX_DOWNLOAD_DURATION", -1.second)
    migration = create_claimed_migration([product_attributes.merge(files: [], covers: [])])

    described_class.new.perform(migration.id)

    expect(seller.links.sole.thumbnail).to be_nil
    expect(migration.reload.results["0"]["warnings"]).to include(a_string_matching(/\AThumbnail .* was not imported: The file download took longer than/))
  end

  it "touches the migration around each transfer" do
    migration = create_claimed_migration([product_attributes.merge(files: [{ url: "https://files.example.com/pack.zip" }, { url: "https://files.example.com/pack.zip" }])])
    touches = 0
    allow_any_instance_of(PartnerMigration).to receive(:touch).and_wrap_original { |original, *args| touches += 1; original.call(*args) }

    described_class.new.perform(migration.id)

    # Once for the product, before and after each of 2 files, then before 1 cover and 1 thumbnail.
    expect(touches).to eq(7)
  end

  it "sets the profile picture of an account that the import created" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])
    migration.update!(account_created: true, profile: { "avatar_url" => "https://files.example.com/wide.png" })

    described_class.new.perform(migration.id)

    expect(seller.reload.avatar).to be_attached
  end

  it "imports the products when the profile picture fails with an unexpected error" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])
    migration.update!(account_created: true, profile: { "avatar_url" => "https://files.example.com/wide.png" })
    allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_raise(ActiveStorage::IntegrityError)

    described_class.new.perform(migration.id)

    expect(migration.reload.status).to eq(PartnerMigration::STATUS_COMPLETED)
    expect(seller.links.sole.name).to eq("Brush Set")
    expect(seller.reload.avatar).not_to be_attached
  end

  it "tries the profile picture only on the first run, so retries do not download it again" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }, { name: "Texture Pack", price: 500 }])
    migration.update!(account_created: true, profile: { "avatar_url" => "https://files.example.com/wide.png" }, results: { "0" => { "product_id" => "saved" } })

    described_class.new.perform(migration.id)

    expect(seller.reload.avatar).not_to be_attached
    expect(seller.links.sole.name).to eq("Texture Pack")
  end

  it "keeps the profile picture of an existing account" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])
    migration.update!(profile: { "avatar_url" => "https://files.example.com/wide.png" })

    described_class.new.perform(migration.id)

    expect(seller.reload.avatar).not_to be_attached
  end

  it "lets Sidekiq retry a temporary download failure" do
    remote_files["https://files.example.com/pack.zip"] = nil
    allow(SsrfFilter).to receive(:get).and_wrap_original do |original, url, &block|
      next original.call(url, &block) unless url.to_s == "https://files.example.com/pack.zip"

      Net::HTTPServiceUnavailable.new("1.1", "503", "")
    end
    migration = create_claimed_migration([product_attributes])

    expect { described_class.new.perform(migration.id) }.to raise_error(PartnerMigration::RemoteFileTransfer::TemporaryError)

    expect(seller.links).to be_empty
    expect(migration.reload.results).to be_nil
    expect(PartnerMigrationNotificationJob.jobs).to be_empty
  end

  it "imports the other products before letting Sidekiq retry a temporary failure" do
    allow(SsrfFilter).to receive(:get).and_wrap_original do |original, url, &block|
      next original.call(url, &block) unless url.to_s == "https://files.example.com/pack.zip"

      Net::HTTPServiceUnavailable.new("1.1", "503", "")
    end
    migration = create_claimed_migration([product_attributes, { name: "Brush Set", price: 500 }])

    expect { described_class.new.perform(migration.id) }.to raise_error(PartnerMigration::RemoteFileTransfer::TemporaryError)

    brush_set = seller.links.sole
    expect(brush_set.name).to eq("Brush Set")
    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, results: { "1" => { "product_id" => brush_set.external_id } })
  end

  it "imports tags that differ only in case once" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500, tags: ["Art", "art"] }])

    described_class.new.perform(migration.id)

    expect(seller.links.sole.tags.pluck(:name)).to eq(["art"])
  end

  it "imports tags that the tags table treats as the same name once" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500, tags: ["café", "cafe"] }])

    described_class.new.perform(migration.id)

    expect(seller.links.sole.tags.pluck(:name)).to eq(["café"])
  end

  it "lets Sidekiq retry a failed DNS lookup" do
    allow(SsrfFilter).to receive(:get).and_raise(SsrfFilter::UnresolvedHostname)
    migration = create_claimed_migration([product_attributes])

    expect { described_class.new.perform(migration.id) }.to raise_error(SsrfFilter::UnresolvedHostname)
    expect(migration.reload.results).to be_nil
  end

  it "records the product before its media, so a retry does not create it again" do
    allow_any_instance_of(PartnerMigration::ProductImporter).to receive(:attach_media).and_raise(Timeout::Error)
    migration = create_claimed_migration([product_attributes])

    expect { described_class.new.perform(migration.id) }.to raise_error(Timeout::Error)
    product_id = seller.links.sole.external_id
    expect(migration.reload.results).to eq("0" => { "product_id" => product_id, "media_pending" => true })

    described_class.new.perform(migration.id)

    expect(seller.links.count).to eq(1)
    expect(migration.reload.status).to eq(PartnerMigration::STATUS_COMPLETED)
    expect(migration.results).to eq("0" => { "product_id" => product_id, "warnings" => ["The import stopped before the covers and thumbnail were added."] })
  end

  it "deletes the files it uploaded when a later file fails" do
    migration = create_claimed_migration([product_attributes.merge(files: [{ url: "https://files.example.com/pack.zip" }, { url: "https://files.example.com/missing.zip" }])])

    described_class.new.perform(migration.id)

    expect(migration.reload.results["0"]).to eq("error" => "The file download failed with HTTP 404.")
    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).objects(prefix: "attachments/#{seller.external_id}/").count).to eq(0)
  end

  it "deletes the files it uploaded when the product cannot be created" do
    allow_any_instance_of(PartnerMigration::ProductImporter).to receive(:create_product!).and_raise(Link::LinkInvalid, "Invalid product")
    migration = create_claimed_migration([product_attributes])

    described_class.new.perform(migration.id)

    expect(migration.reload.results["0"]).to eq("error" => "Invalid product")
    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).objects(prefix: "attachments/#{seller.external_id}/").count).to eq(0)
  end

  it "deletes a thumbnail upload that fails validation" do
    migration = create_claimed_migration([product_attributes.merge(thumbnail_url: "https://files.example.com/wide.png")])

    described_class.new.perform(migration.id)

    expect(migration.reload.results["0"]["warnings"]).to include(a_string_starting_with("Thumbnail https://files.example.com/wide.png was not imported"))
    expect(ActiveStorage::Blob.where(filename: "wide.png")).to be_empty
  end

  it "keeps the files of a saved product when an after_commit callback raises" do
    raised = false
    allow(ActiveRecord::Base).to receive(:transaction).and_wrap_original do |original, *args, **kwargs, &block|
      result = original.call(*args, **kwargs, &block)
      if result.is_a?(Link) && !raised
        raised = true
        raise ActiveRecord::RecordInvalid
      end
      result
    end
    migration = create_claimed_migration([product_attributes])

    expect { described_class.new.perform(migration.id) }.to raise_error(ActiveRecord::RecordInvalid)

    product = seller.links.sole
    expect(migration.reload.results["0"]).to eq("product_id" => product.external_id, "media_pending" => true)
    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).objects(prefix: "attachments/#{seller.external_id}/").count).to eq(1)
  end

  it "skips products that a previous attempt imported" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }, { name: "Texture Pack", price: 1500 }])
    migration.update!(results: { "0" => { "product_id" => "already-imported" } })

    described_class.new.perform(migration.id)

    expect(seller.links.pluck(:name)).to eq(["Texture Pack"])
    expect(migration.reload.results.keys).to eq(["0", "1"])
  end

  it "does nothing for a migration that is not claimed" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])
    migration.update!(status: PartnerMigration::STATUS_PENDING)

    described_class.new.perform(migration.id)

    expect(seller.links).to be_empty
  end

  it "marks the migration as failed when retries run out" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])

    described_class.sidekiq_retries_exhausted_block.call({ "args" => [migration.id] }, StandardError.new("Network down"))

    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_FAILED, completed_at: be_present, failure_reason: "Network down")
    expect(PartnerMigrationNotificationJob).to have_enqueued_sidekiq_job(migration.id)
  end

  it "retries a failed notification enqueue without importing products again" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])
    allow(PartnerMigrationNotificationJob).to receive(:perform_async).and_raise(Redis::BaseError, "Redis unavailable")

    expect { described_class.new.perform(migration.id) }.to raise_error(Redis::BaseError)
    expect(migration.reload.status).to eq(PartnerMigration::STATUS_COMPLETED)
    allow(PartnerMigrationNotificationJob).to receive(:perform_async).and_call_original

    expect { described_class.new.perform(migration.id) }.not_to change { seller.links.count }
    expect(PartnerMigrationNotificationJob).to have_enqueued_sidekiq_job(migration.id)
  end

  it "keeps a completed import when notification enqueues exhaust their retries" do
    migration = create_claimed_migration([{ name: "Brush Set", price: 500 }])
    migration.update!(status: PartnerMigration::STATUS_COMPLETED, completed_at: Time.current)

    described_class.sidekiq_retries_exhausted_block.call({ "args" => [migration.id] }, StandardError.new("Redis unavailable"))

    expect(migration.reload).to have_attributes(status: PartnerMigration::STATUS_COMPLETED, failure_reason: nil)
    expect(PartnerMigrationNotificationJob).to have_enqueued_sidekiq_job(migration.id)
  end
end
