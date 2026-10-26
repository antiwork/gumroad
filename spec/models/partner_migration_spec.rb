# frozen_string_literal: true

require "spec_helper"

describe PartnerMigration do
  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:product_attributes) { { name: "Texture Pack", price: 1500 } }
  let(:creator) { create(:user) }

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
  end

  describe "#claim!" do
    it "links the creator to the partner user ID and starts the import" do
      migration, _code = create_migration

      migration.claim!(creator)

      expect(migration.reload).to have_attributes(status: described_class::STATUS_CLAIMED, user: creator, claimed_at: be_present)
      expect(partner_application.partner_creators.alive.find_by(external_user_id: "ext-1")).to have_attributes(user: creator, migrated_at: be_present)
      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
    end

    it "cannot be claimed by a second account" do
      migration, _code = create_migration
      migration.claim!(creator)

      expect { migration.claim!(create(:user)) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "queues the import again when the same creator claims again before it finishes" do
      migration, _code = create_migration
      migration.claim!(creator)
      Sidekiq::Worker.clear_all

      migration.claim!(creator)

      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
      migration.update!(status: described_class::STATUS_COMPLETED)
      expect { migration.claim!(creator) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects an expired link" do
      migration, _code = create_migration
      migration.update!(expires_at: 1.minute.ago)

      expect { migration.claim!(creator) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects a link from an application that is no longer a partner" do
      migration, _code = create_migration
      partner_application.update!(is_partner: false)

      expect { migration.claim!(creator) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects a partner user ID that is linked to a different Gumroad account" do
      PartnerCreator.create!(oauth_application: partner_application, user: create(:user), external_user_id: "ext-1")
      migration, _code = create_migration

      expect { migration.claim!(creator) }.to raise_error(described_class::ClaimError, "This Example App account is already linked to a different Gumroad account.")
      expect(migration.reload).to be_pending
    end

    it "rejects a Gumroad account that is linked to a different partner user ID" do
      PartnerCreator.create!(oauth_application: partner_application, user: creator, external_user_id: "ext-2")
      migration, _code = create_migration

      expect { migration.claim!(creator) }.to raise_error(described_class::ClaimError, "Your Gumroad account is already linked to a different Example App account.")
    end

    it "restores a creator that was removed from the program" do
      partner_creator = PartnerCreator.create!(oauth_application: partner_application, user: creator, external_user_id: "ext-1")
      partner_creator.mark_deleted!
      migration, _code = create_migration

      migration.claim!(creator)

      expect(partner_creator.reload).to be_alive
    end

    it "rejects a suspended account" do
      migration, _code = create_migration
      creator.update!(user_risk_state: "suspended_for_fraud")

      expect { migration.claim!(creator) }.to raise_error(described_class::ClaimError, "This account cannot import products.")
    end
  end
end
