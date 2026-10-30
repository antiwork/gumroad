# frozen_string_literal: true

require "spec_helper"

describe Onetime::RepairTruncatedPurchaseJsonData, versioning: true do
  let(:purchase) { create(:purchase) }
  let!(:cut_version) do
    purchase.update!(locale: "en", perceived_price_cents: 1000, recommender_model_name: RecommendedProductsService::MODEL_SALES,
                     card_country_source: "stripe", last_content_page_id: "p" * 300)
    purchase.versions.last
  end
  let(:full_json_data) { JSON.parse(cut_version.object_changes)["json_data"].last }
  let(:stored_json_data) { full_json_data.first(described_class::TRUNCATED_LENGTH) }
  let(:target) { { purchase_id: purchase.id, version_id: cut_version.id, stored_json_data:, approved_json_data: full_json_data } }

  before { Purchase.where(id: purchase.id).update_all(["json_data = ?", stored_json_data]) }

  def status_for(target, dry_run: false)
    described_class.new(targets: [target], dry_run:).process.sole[:status]
  end

  def stored_value
    purchase.reload.read_attribute_before_type_cast(:json_data)
  end

  it "reports without writing by default" do
    expect(described_class.new(targets: [target]).process).to eq([{ purchase_id: purchase.id, version_id: cut_version.id, status: :dry_run }])
    expect(stored_value).to eq(stored_json_data)
  end

  it "restores every key the cut write recorded, once, and records the change" do
    expect { expect(status_for(target)).to eq(:repaired) }.to change { purchase.versions.count }.by(1)
    expect(purchase.reload.json_data).to eq(JSON.parse(full_json_data))
    expect(purchase.last_content_page_id).to eq("p" * 300)
    audit = purchase.versions.last
    expect(audit).to have_attributes(event: "update", whodunnit: described_class.name)
    expect(JSON.parse(audit.object_changes)).to eq("json_data" => [stored_json_data, full_json_data])

    expect { expect(status_for(target)).to eq(:already_repaired) }.not_to change { purchase.versions.count }
  end

  it "keeps the cut value when the change cannot be recorded" do
    allow(PaperTrail::Version).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

    expect { status_for(target) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(stored_value).to eq(stored_json_data)
  end

  it "refuses a completion that the version did not record" do
    guessed_json_data = "#{stored_json_data}\"}"

    expect(status_for(target.merge(approved_json_data: guessed_json_data))).to eq(:version_does_not_record_approved_value)
    expect(stored_value).to eq(stored_json_data)
  end

  it "refuses the snapshot from before the cut write, which lacks its keys" do
    snapshot_json_data = JSON.parse(cut_version.object)["json_data"]

    expect(status_for(target.merge(approved_json_data: snapshot_json_data))).to eq(:approved_value_not_a_full_hash)
    expect(stored_value).to eq(stored_json_data)
  end

  it "refuses when the row holds a different cut value than the version wrote" do
    unversioned_json_data = { "locale" => "fr", "last_content_page_id" => "q" * 300 }.to_json.first(described_class::TRUNCATED_LENGTH)
    Purchase.where(id: purchase.id).update_all(["json_data = ?", unversioned_json_data])

    expect(unversioned_json_data.length).to eq(described_class::TRUNCATED_LENGTH)
    expect(status_for(target.merge(stored_json_data: unversioned_json_data))).to eq(:approved_value_does_not_extend_stored)
    expect(stored_value).to eq(unversioned_json_data)
  end

  it "skips a row that changed after the target was prepared" do
    changed_json_data = stored_json_data.sub("stripe", "geoip")
    Purchase.where(id: purchase.id).update_all(["json_data = ?", changed_json_data])

    expect(status_for(target)).to eq(:row_changed)
    expect(stored_value).to eq(changed_json_data)
  end

  it "skips a row that is exactly 255 characters of valid JSON" do
    valid_json_data = { "locale" => "en", "last_content_page_id" => "" }.to_json
    valid_json_data = { "locale" => "en", "last_content_page_id" => "v" * (described_class::TRUNCATED_LENGTH - valid_json_data.length) }.to_json
    Purchase.where(id: purchase.id).update_all(["json_data = ?", valid_json_data])

    expect(valid_json_data.length).to eq(described_class::TRUNCATED_LENGTH)
    expect(status_for(target.merge(stored_json_data: valid_json_data))).to eq(:not_truncated)
    expect(stored_value).to eq(valid_json_data)
  end

  it "skips a row whose json_data is NULL" do
    Purchase.where(id: purchase.id).update_all("json_data = NULL")

    expect(stored_value).to be_nil
    expect(status_for(target.merge(stored_json_data: nil))).to eq(:not_truncated)
  end

  it "refuses a missing version and a version of another purchase" do
    other_version = create(:purchase).versions.last

    expect(status_for(target.merge(version_id: PaperTrail::Version.maximum(:id) + 1))).to eq(:version_not_found)
    expect(status_for(target.merge(version_id: other_version.id))).to eq(:version_not_found)
    expect(stored_value).to eq(stored_json_data)
  end

  it "refuses when a later version may have changed json_data" do
    PaperTrail::Version.create!(item_type: "Purchase", item_id: purchase.id, event: "update", object_changes: nil)

    expect(status_for(target)).to eq(:later_version_may_change_json_data)
    expect(stored_value).to eq(stored_json_data)
  end

  it "reports a missing purchase" do
    expect(status_for(target.merge(purchase_id: Purchase.maximum(:id) + 1))).to eq(:purchase_not_found)
  end

  it "refuses to run until purchases.json_data is LONGTEXT" do
    service = described_class.new(targets: [target], dry_run: false)
    allow(service).to receive(:json_data_column_type).and_return("varchar(255)")

    expect { service.process }.to raise_error("purchases.json_data must be LONGTEXT before repairing")
    expect(stored_value).to eq(stored_json_data)
  end
end
