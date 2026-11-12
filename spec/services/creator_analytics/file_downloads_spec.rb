# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::FileDownloads do
  let(:seller) { create(:user, timezone: "UTC") }
  let(:product) { create(:product, user: seller, name: "Guide") }
  let(:file) { create(:product_file, link: product, display_name: "Chapter 1") }
  let(:other_seller_file) { create(:product_file, display_name: "Not mine") }

  def record(event_type, file, purchase_id:, at:)
    travel_to(at) do
      ConsumptionEvent.create_event!(
        event_type:,
        platform: Platform::WEB,
        url_redirect_id: 1,
        product_file_id: file&.id,
        purchase_id:,
        product_id: file&.link_id,
        ip_address: "127.0.0.1",
      )
    end
  end

  def by_file(start_date, end_date)
    described_class.new(seller:, start_date:, end_date:).by_file
  end

  it "counts downloads and distinct purchases per file within the range" do
    record("download", file, purchase_id: 1, at: Time.utc(2026, 1, 1, 10))
    record("download", file, purchase_id: 1, at: Time.utc(2026, 1, 2, 10))
    record("download", file, purchase_id: 2, at: Time.utc(2026, 1, 3, 10))

    expected = {
      id: file.external_id,
      product_permalink: product.unique_permalink,
      product_name: "Guide",
      name: "Chapter 1",
      deleted: false,
      downloads: 3,
      unique_buyers: 2,
    }
    expect(by_file(Date.new(2026, 1, 1), Date.new(2026, 1, 3))).to eq([expected])
  end

  it "ignores other event types, events outside the range, and other sellers' files" do
    record("download", file, purchase_id: 1, at: Time.utc(2026, 1, 2, 10))
    record("watch", file, purchase_id: 1, at: Time.utc(2026, 1, 2, 10))
    record("read", file, purchase_id: 1, at: Time.utc(2026, 1, 2, 10))
    record("download", file, purchase_id: 1, at: Time.utc(2025, 12, 31, 23, 59))
    record("download", file, purchase_id: 1, at: Time.utc(2026, 1, 4))
    record("download", other_seller_file, purchase_id: 3, at: Time.utc(2026, 1, 2, 10))
    record("download_all", nil, purchase_id: 1, at: Time.utc(2026, 1, 2, 10))

    expect(by_file(Date.new(2026, 1, 1), Date.new(2026, 1, 3))).to contain_exactly(
      a_hash_including(name: "Chapter 1", downloads: 1, unique_buyers: 1)
    )
  end

  it "keeps downloads of deleted files and files of deleted products" do
    deleted_file = create(:product_file, link: product, display_name: "Old chapter", deleted_at: Time.current)
    deleted_product = create(:product, user: seller, deleted_at: Time.current)
    file_of_deleted_product = create(:product_file, link: deleted_product, display_name: "Retired")
    record("download", deleted_file, purchase_id: 1, at: Time.utc(2026, 1, 2))
    record("download", file_of_deleted_product, purchase_id: 2, at: Time.utc(2026, 1, 2))

    expect(by_file(Date.new(2026, 1, 1), Date.new(2026, 1, 3))).to contain_exactly(
      a_hash_including(name: "Old chapter", deleted: true, downloads: 1),
      a_hash_including(name: "Retired", product_permalink: deleted_product.unique_permalink, deleted: false, downloads: 1),
    )
  end

  it "bounds the range by days in the seller's time zone" do
    seller.update!(timezone: "Pacific Time (US & Canada)")
    # 23:00 on Jan 1 in Pacific time.
    record("download", file, purchase_id: 1, at: Time.utc(2026, 1, 2, 7))
    # 01:00 on Jan 2 in Pacific time.
    record("download", file, purchase_id: 2, at: Time.utc(2026, 1, 2, 9))

    expect(by_file(Date.new(2026, 1, 1), Date.new(2026, 1, 1))).to contain_exactly(a_hash_including(downloads: 1, unique_buyers: 1))
  end

  it "combines files counted in separate queries" do
    stub_const("#{described_class}::FILE_IDS_PER_QUERY", 1)
    second_file = create(:product_file, link: product, display_name: "Chapter 2")
    record("download", file, purchase_id: 1, at: Time.utc(2026, 1, 2))
    record("download", second_file, purchase_id: 1, at: Time.utc(2026, 1, 2))

    expect(by_file(Date.new(2026, 1, 1), Date.new(2026, 1, 3)).map { _1[:name] }).to contain_exactly("Chapter 1", "Chapter 2")
  end
end
