# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261222000001_create_seller_plan_offers").to_s
require Rails.root.join("db/migrate/20261223000001_add_team_membership_id_to_oauth_access_tokens").to_s

describe AddTeamMembershipIdToOauthAccessTokens do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }

  # DDL is not rolled back with the example, so put back anything the example dropped.
  after do
    connection.add_column(:oauth_access_tokens, :team_membership_id, :bigint, if_not_exists: true)
    connection.add_index(:oauth_access_tokens, :team_membership_id, if_not_exists: true)
    CreateSellerPlanOffers.new.migrate(:up) unless connection.table_exists?(:seller_plan_offers)
  end

  def token_column? = connection.column_exists?(:oauth_access_tokens, :team_membership_id)

  def token_index? = connection.index_exists?(:oauth_access_tokens, :team_membership_id)

  def seller_plan_offers_schema
    columns = connection.columns(:seller_plan_offers).map { [_1.name, _1.sql_type, _1.null, _1.default] }
    indexes = connection.indexes(:seller_plan_offers).map { [_1.name, _1.columns, _1.unique] }
    [columns, indexes.sort]
  end

  def drop_token_column
    connection.remove_column(:oauth_access_tokens, :team_membership_id)
  end

  # schema.rb records 20261222000001 for main's CreateSellerPlanOffers, as a database migrated from
  # main does.
  it "adds the column without touching seller_plan_offers on a database migrated from main" do
    drop_token_column
    schema = seller_plan_offers_schema

    migration.migrate(:up)

    expect(token_column?).to eq(true)
    expect(token_index?).to eq(true)
    expect(seller_plan_offers_schema).to eq(schema)
  end

  it "keeps existing seller_plan_offers rows" do
    offer = SellerPlanOffer.create!(user: create(:user), arm: "five", price_cents: 500, offered_at: Time.current)

    expect { migration.migrate(:up) }.not_to change { SellerPlanOffer.pluck(:id, :updated_at) }
    expect(offer.reload).to be_present
  end

  # A preview database that ran the token migration under 20261222000001 has the column and that
  # row, but never ran main's CreateSellerPlanOffers.
  it "creates seller_plan_offers where the superseded token migration took its version" do
    schema = seller_plan_offers_schema
    connection.drop_table(:seller_plan_offers)

    migration.migrate(:up)

    expect(connection.table_exists?(:seller_plan_offers)).to eq(true)
    expect(seller_plan_offers_schema).to eq(schema)
    expect(token_column?).to eq(true)
  end

  it "can run up twice" do
    connection.drop_table(:seller_plan_offers)
    migration.migrate(:up)
    schema = seller_plan_offers_schema

    expect { migration.migrate(:up) }.not_to raise_error
    expect(seller_plan_offers_schema).to eq(schema)
    expect(token_column?).to eq(true)
  end

  it "refuses to roll back and leaves the schema in place" do
    expect { migration.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect(token_column?).to eq(true)
    expect(connection.table_exists?(:seller_plan_offers)).to eq(true)
  end
end
