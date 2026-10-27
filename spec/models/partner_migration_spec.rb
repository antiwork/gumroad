# frozen_string_literal: true

require "spec_helper"

describe PartnerMigration do
  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:product_attributes) { { name: "Texture Pack", price: 1500 } }
  let(:seller) { create(:user) }

  def create_migration(external_user_id: "ext-1")
    products, _error = described_class.normalize_products([product_attributes])
    described_class.create_for!(oauth_application: partner_application, external_user_id:, products:)
  end

  describe ".normalize_products" do
    it "keeps only the supported keys and fills in defaults" do
      products, error = described_class.normalize_products([product_attributes.merge(unknown: "x", variant_categories: [{ title: "License", variants: [{ name: "Standard" }] }])])

      expect(error).to be_nil
      expect(products).to eq([{
                               "name" => "Texture Pack",
                               "description" => nil,
                               "price" => 1500,
                               "price_currency_type" => "usd",
                               "taxonomy_id" => nil,
                               "tags" => [],
                               "files" => [],
                               "covers" => [],
                               "thumbnail_url" => nil,
                               "variant_categories" => [{ "title" => "License", "variants" => [{ "name" => "Standard", "price_difference_cents" => 0 }] }],
                             }])
    end

    it "rejects an empty list" do
      expect(described_class.normalize_products([])).to eq([nil, "products must be an array with 1 to #{described_class::MAX_PRODUCTS} items."])
    end

    it "names the product that is not valid" do
      _products, error = described_class.normalize_products([product_attributes, { name: "No price" }])

      expect(error).to eq("products[1]: price must be a whole number of cents, 0 or more.")
    end

    it "rejects a file URL that is not https" do
      _products, error = described_class.normalize_products([product_attributes.merge(files: [{ url: "http://files.example.com/pack.zip" }])])

      expect(error).to eq("products[0]: each file needs an https url and an optional display_name string.")
    end

    it "rejects more than one variant category" do
      category = { title: "License", variants: [{ name: "Standard" }] }
      _products, error = described_class.normalize_products([product_attributes.merge(variant_categories: [category, category])])

      expect(error).to eq("products[0]: variant_categories must be an array with up to 1 item.")
    end

    it "rejects a variant price difference above the maximum price" do
      category = { title: "License", variants: [{ name: "Commercial", price_difference_cents: BasePrice::Shared::MAX_PRICE_CENTS + 1 }] }
      _products, error = described_class.normalize_products([product_attributes.merge(variant_categories: [category])])

      expect(error).to eq("products[0]: each variant needs a name string and a whole number price_difference_cents from 0 to #{BasePrice::Shared::MAX_PRICE_CENTS}.")
    end

    it "rejects blank and oversized variant names and category titles" do
      ["", " ", "x" * (described_class::MAX_NAME_LENGTH + 1)].each do |name|
        category = { title: "License", variants: [{ name: }] }
        expect(described_class.normalize_products([product_attributes.merge(variant_categories: [category])]).last).to include("variant name")
        category = { title: name, variants: [{ name: "Standard" }] }
        expect(described_class.normalize_products([product_attributes.merge(variant_categories: [category])]).last).to include("variant category title")
      end
    end

    it "rejects a combined product and variant price above the stored range" do
      category = { title: "License", variants: [{ name: "Commercial", price_difference_cents: BasePrice::Shared::MAX_PRICE_CENTS }] }

      expect(described_class.normalize_products([product_attributes.merge(variant_categories: [category])]).last).to include("product price plus each variant")
    end

    it "rejects a file display name that would be truncated" do
      product = product_attributes.merge(files: [{ url: "https://files.example.com/pack.zip", display_name: "x" * (described_class::MAX_NAME_LENGTH + 1) }])

      expect(described_class.normalize_products([product]).last).to include("file display_name")
    end

    it "rejects a price above the maximum price" do
      _products, error = described_class.normalize_products([product_attributes.merge(price: BasePrice::Shared::MAX_PRICE_CENTS + 1)])

      expect(error).to eq("products[0]: price must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents.")
    end

    it "rejects more tags than a product can have" do
      tags = Array.new(described_class::MAX_TAGS_PER_PRODUCT + 1) { "tag#{_1}" }
      _products, error = described_class.normalize_products([product_attributes.merge(tags:)])

      expect(error).to eq("products[0]: tags must be an array of up to #{described_class::MAX_TAGS_PER_PRODUCT} strings.")
    end

    it "rejects a price below the currency's minimum" do
      _products, error = described_class.normalize_products([product_attributes.merge(price: 50)])

      expect(error).to eq("products[0]: price must be 0 or at least 99 cents in usd.")
    end

    it "cleans tags the way products save them and drops duplicates" do
      products, _error = described_class.normalize_products([product_attributes.merge(tags: [" Art ", "art", "Digital  Art"])])

      expect(products.first["tags"]).to eq(["art", "digital art"])
    end

    it "drops tags that the tags table treats as the same name" do
      products, _error = described_class.normalize_products([product_attributes.merge(tags: ["café", "cafe", "straße", "strasse"])])

      expect(products.first["tags"]).to eq(["café", "straße"])
    end

    it "rejects a tag that a product cannot use" do
      _products, error = described_class.normalize_products([product_attributes.merge(tags: ["textures", "x" * 21])])

      expect(error).to eq("products[0]: tags: A tag is too long. Please try again with a shorter one, under 20 characters.")
    end

    it "rejects an unknown taxonomy" do
      _products, error = described_class.normalize_products([product_attributes.merge(taxonomy_id: 0)])

      expect(error).to eq("products[0]: taxonomy_id is not a known category.")
    end
  end

  describe ".create_for!" do
    it "stores only a digest of the code" do
      migration, code = create_migration

      expect(migration.code_digest).to eq(described_class.digest(code))
      expect(migration.code_digest).not_to eq(code)
      expect(described_class.find_by_code(code)).to eq(migration)
      expect(migration.expires_at).to be_within(1.minute).of(described_class::EXPIRES_IN.from_now)
    end

    it "reuses one migration when the partner retries a seller export" do
      first, first_code = create_migration
      second, second_code = create_migration

      expect(second.id).to eq(first.id)
      expect(first_code).not_to eq(second_code)
      expect(described_class.find_by_code(first_code)).to be_nil
      expect(described_class.find_by_code(second_code)).to eq(first)
    end

    it "refreshes signed URLs without clearing products that already imported" do
      original = product_attributes.merge(files: [{ url: "https://files.example.com/pack.zip?signature=old" }])
      products, = described_class.normalize_products([original])
      migration, = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(results: { "0" => { "product_id" => "saved-product" } })
      products, = described_class.normalize_products([original.merge(files: [{ url: "https://files.example.com/pack.zip?signature=new" }])])

      refreshed, = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

      expect(refreshed.id).to eq(migration.id)
      expect(refreshed.results).to eq("0" => { "product_id" => "saved-product" })
      expect(refreshed.products.first["files"].first["url"]).to end_with("signature=new")
    end

    it "rejects catalog changes after the seller confirms" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      products, = described_class.normalize_products([product_attributes.merge(name: "Another product")])

      expect { described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:) }.to raise_error(described_class::CatalogConflict)
      expect(migration.reload.products.first["name"]).to eq("Texture Pack")
    end

    it "gives each migration its own Nano ID and keeps it when the partner sends the export again" do
      first, = create_migration
      other, = create_migration(external_user_id: "ext-2")
      again, = create_migration

      expect(first.public_id).to match(/\A[A-Za-z0-9_-]{21}\z/)
      expect(other.public_id).not_to eq(first.public_id)
      expect(again.id).to eq(first.id)
      expect(again.reload.public_id).to eq(first.public_id)
    end
  end

  describe "#public_id" do
    it "cannot be changed" do
      migration, = create_migration
      public_id = migration.public_id

      expect { migration.update!(public_id: Nanoid.generate) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(migration.reload.public_id).to eq(public_id)
    end
  end

  describe ".find_by_public_id" do
    let(:public_id) { "aB3xaB3xaB3xaB3xaB3x_" }
    let!(:migration) do
      products, _error = described_class.normalize_products([product_attributes])
      described_class.create!(oauth_application: partner_application, external_user_id: "ext-1", products:, code_digest: described_class.digest("code"), expires_at: 1.day.from_now, public_id:)
    end

    it "finds a migration by its exact Nano ID" do
      expect(described_class.find_by_public_id(public_id)).to eq(migration)
    end

    it "does not find a migration by its row ID, another case, or extra characters" do
      [migration.id, migration.id.to_s, public_id.swapcase, public_id.upcase, "#{public_id} ", " #{public_id}", "#{public_id}\n", public_id.chop, "#{public_id}x", "", nil, [public_id]].each do |value|
        expect(described_class.find_by_public_id(value)).to be_nil, "found a migration for #{value.inspect}"
      end
      expect(described_class.where(public_id: "#{public_id} ")).not_to exist
      expect(described_class.where(public_id: public_id.swapcase)).not_to exist
    end

    it "still finds a migration by a signed ID issued before Nano IDs" do
      expect(described_class.find_by_public_id(migration.signed_id(purpose: :partner_migration))).to eq(migration)
      expect(described_class.find_by_public_id("#{migration.signed_id(purpose: :partner_migration)} ")).to be_nil
      expect(described_class.find_by_public_id(migration.signed_id)).to be_nil
      expect(described_class.find_by_public_id(migration.signed_id(purpose: :another_purpose))).to be_nil
    end
  end

  describe "#claim!" do
    it "requires an email address for the result notification" do
      migration, = create_migration
      seller.update_columns(provider: "apple", email: nil, unconfirmed_email: nil)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, /Add an email address/)

      expect(migration.reload).to be_pending
      expect(PartnerMigrationImportJob.jobs).to be_empty
    end

    it "rejects a catalog refreshed after the confirmation page loads" do
      migration, = create_migration
      products, = described_class.normalize_products([product_attributes.merge(name: "Replacement catalog")])
      described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, /out of date/)

      expect(migration.reload).to be_pending
      expect(partner_application.partner_sellers).to be_empty
      expect(PartnerMigrationImportJob.jobs).to be_empty
    end

    it "links the seller to the partner user ID and starts the import" do
      migration, _code = create_migration

      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect(migration.reload).to have_attributes(status: described_class::STATUS_CLAIMED, user: seller, claimed_at: be_present)
      expect(partner_application.partner_sellers.alive.find_by(external_user_id: "ext-1")).to have_attributes(user: seller, migrated_at: nil)
      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
    end

    it "cannot be claimed by a second account" do
      migration, _code = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect { migration.claim!(create(:user), expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "queues the import again when the same seller claims again before it finishes" do
      migration, _code = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      Sidekiq::Worker.clear_all

      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
      migration.update!(status: described_class::STATUS_COMPLETED)
      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects an expired link" do
      migration, _code = create_migration
      migration.update!(expires_at: 1.minute.ago)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects a link from an application that is no longer a partner" do
      migration, _code = create_migration
      partner_application.update!(is_partner: false)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects a partner user ID that is linked to a different Gumroad account" do
      create(:partner_seller, oauth_application: partner_application, user: create(:user), external_user_id: "ext-1")
      migration, _code = create_migration

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This Example App account is already linked to a different Gumroad account.")
      expect(migration.reload).to be_pending
    end

    it "rejects a Gumroad account that is linked to a different partner user ID" do
      create(:partner_seller, oauth_application: partner_application, user: seller, external_user_id: "ext-2")
      migration, _code = create_migration

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "Your Gumroad account is already linked to a different Example App account.")
    end

    it "restores a seller that was removed from the program" do
      partner_seller = create(:partner_seller, oauth_application: partner_application, user: seller, external_user_id: "ext-1")
      partner_seller.mark_deleted!
      migration, _code = create_migration

      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect(partner_seller.reload).to be_alive
    end

    it "links partner user IDs that differ only in case, accents, Unicode form or trailing spaces to different accounts" do
      external_user_ids = ["aB3x", "Ab3X", "café", "cafe", "\u00e9", "e\u0301", "ext-9", "ext-9 "]

      external_user_ids.each do |external_user_id|
        migration, _code = create_migration(external_user_id:)
        claimer = create(:user)

        migration.claim!(claimer, expected_code_digest: migration.code_digest)

        expect(partner_application.partner_sellers.where(external_user_id:).sole).to have_attributes(user: claimer, external_user_id:)
      end
      expect(partner_application.partner_sellers.pluck(:external_user_id)).to match_array(external_user_ids)
    end

    it "rejects a suspended account" do
      migration, _code = create_migration
      seller.update!(user_risk_state: "suspended_for_fraud")

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This account cannot import products.")
    end

    it "starts the migration date when an imported product first goes live" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      PartnerMigrationImportJob.new.perform(migration.id)
      partner_seller = partner_application.partner_sellers.sole
      expect(partner_seller.migrated_at).to be_nil

      seller.links.sole.publish!

      expect(partner_seller.reload.migrated_at).to eq(seller.links.sole.first_published_at)
    end

    it "retries only failed products and preserves saved products" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(status: described_class::STATUS_FAILED, results: { "0" => { "product_id" => "saved" }, "1" => { "error" => "Missing file" } })

      migration.retry!(seller)

      expect(migration.reload).to have_attributes(status: described_class::STATUS_CLAIMED, results: { "0" => { "product_id" => "saved" } })
      expect { migration.retry!(create(:user)) }.to raise_error(described_class::ClaimError)
    end

    it "keeps failed results when the previous job still holds its queue lock" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      results = { "0" => { "error" => "Missing file" } }
      migration.update!(status: described_class::STATUS_FAILED, results:)
      allow(PartnerMigrationImportJob).to receive(:perform_async).with(migration.id).and_return(nil)

      expect { migration.retry!(seller) }.to raise_error(described_class::ClaimError, /still finishing/)
      expect(migration.reload).to have_attributes(status: described_class::STATUS_FAILED, results:)
    end

    it "tells the seller when a resumed import is still running" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      allow(PartnerMigrationImportJob).to receive(:perform_async).with(migration.id).and_return(nil)

      expect { migration.retry!(seller) }.to raise_error(described_class::ClaimError, "The import is still running. Large files can take a few hours.")
    end

    it "rejects a retry from a stale form after the import finishes" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(status: described_class::STATUS_COMPLETED, completed_at: Time.current, notified_at: Time.current)
      notified_at = migration.reload.notified_at

      expect { migration.retry!(seller) }.to raise_error(described_class::ClaimError, "This import is already complete.")

      expect(migration.reload).to have_attributes(status: described_class::STATUS_COMPLETED, notified_at:)
      expect(PartnerMigrationImportJob.jobs.size).to eq(1)
    end
  end
end
