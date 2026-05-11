# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::CursorPagination do
  let(:base_time) { Time.zone.local(2026, 1, 15, 12, 0, 0) }
  let(:default_order) { [[:created_at, :desc], [:id, :desc]] }

  describe ".encode and .decode" do
    it "round trips a cursor payload" do
      payload = { "created_at" => base_time.iso8601, "id" => 123 }

      token = described_class.encode(payload)

      expect(described_class.decode(token)).to eq(payload)
    end

    it "raises InvalidCursor for bad cursor tokens" do
      bad_tokens = [
        "",
        "garbage",
        Base64.urlsafe_encode64("not-json"),
        Base64.urlsafe_encode64(JSON.dump({ "id" => 1 })),
        signed_token("not-json"),
        signed_token(JSON.dump(["id", 1]))
      ]

      bad_tokens.each do |token|
        expect { described_class.decode(token) }.to raise_error(described_class::InvalidCursor), "token=#{token.inspect}"
      end
    end
  end

  describe ".paginate" do
    it "returns up to the limit and emits a next cursor when another page exists" do
      newest = create_payment(created_at: base_time)
      middle = create_payment(created_at: base_time - 1.minute)
      create_payment(created_at: base_time - 2.minutes)

      records, next_cursor = described_class.paginate(payment_scope, limit: 2, order: default_order)

      expect(records).to eq([newest, middle])
      expect(next_cursor).to be_present
    end

    it "returns a nil next cursor on the last page" do
      first = create_payment(created_at: base_time)
      second = create_payment(created_at: base_time - 1.minute)

      records, next_cursor = described_class.paginate(payment_scope, limit: 3, order: default_order)

      expect(records).to eq([first, second])
      expect(next_cursor).to be_nil
    end

    it "walks the full result set in pages without duplicates or gaps" do
      create_payment(created_at: base_time)
      create_payment(created_at: base_time - 1.minute)
      create_payment(created_at: base_time - 2.minutes)
      create_payment(created_at: base_time - 3.minutes)
      create_payment(created_at: base_time - 4.minutes)
      seen_ids = []
      cursor = nil

      loop do
        records, cursor = described_class.paginate(payment_scope, cursor:, limit: 2, order: default_order)
        seen_ids.concat(records.map(&:id))
        break if cursor.nil?
      end

      expect(seen_ids).to eq(payment_scope.order(created_at: :desc, id: :desc).pluck(:id))
      expect(seen_ids.uniq).to eq(seen_ids)
    end

    it "does not include a row inserted before the cursor during a paginated walk" do
      newest = create_payment(created_at: base_time)
      middle = create_payment(created_at: base_time - 1.minute)
      oldest = create_payment(created_at: base_time - 2.minutes)

      first_page, cursor = described_class.paginate(payment_scope, limit: 2, order: default_order)
      inserted = create_payment(created_at: base_time + 1.minute)
      second_page, next_cursor = described_class.paginate(payment_scope, cursor:, limit: 2, order: default_order)

      expect(first_page).to eq([newest, middle])
      expect(second_page).to eq([oldest])
      expect(second_page).not_to include(inserted)
      expect(next_cursor).to be_nil
    end

    it "uses later order columns when records share the leading sort key" do
      older = create_payment(created_at: base_time - 1.minute)
      first = create_payment(created_at: base_time)
      second = create_payment(created_at: base_time)

      first_page, cursor = described_class.paginate(payment_scope, limit: 1, order: default_order)
      second_page, next_cursor = described_class.paginate(payment_scope, cursor:, limit: 2, order: default_order)

      expect(first_page).to eq([second])
      expect(second_page).to eq([first, older])
      expect(next_cursor).to be_nil
    end

    it "honors ascending order" do
      oldest = create_payment(created_at: base_time - 2.minutes)
      middle = create_payment(created_at: base_time - 1.minute)
      newest = create_payment(created_at: base_time)
      order = [[:created_at, :asc], [:id, :asc]]

      first_page, cursor = described_class.paginate(payment_scope, limit: 2, order:)
      second_page, next_cursor = described_class.paginate(payment_scope, cursor:, limit: 2, order:)

      expect(first_page).to eq([oldest, middle])
      expect(second_page).to eq([newest])
      expect(next_cursor).to be_nil
    end

    it "returns an empty page for an empty scope" do
      records, next_cursor = described_class.paginate(Payment.none, limit: 2, order: default_order)

      expect(records).to eq([])
      expect(next_cursor).to be_nil
    end

    it "raises ArgumentError for invalid pagination configuration" do
      expect { described_class.paginate(payment_scope, order: []) }.to raise_error(ArgumentError, /order/)
      expect { described_class.paginate(payment_scope, order: [[:id, :sideways]]) }.to raise_error(ArgumentError, /direction/)
      expect { described_class.paginate(payment_scope, order: [[:id, nil]]) }.to raise_error(ArgumentError, /direction/)
    end

    it "raises InvalidCursor when the cursor keys do not match the order columns" do
      mismatched_cursor = described_class.encode("id" => 1)

      expect do
        described_class.paginate(payment_scope, cursor: mismatched_cursor, order: default_order)
      end.to raise_error(described_class::InvalidCursor)
    end
  end

  def create_payment(created_at:)
    create(:payment, created_at:, updated_at: created_at)
  end

  def payment_scope
    Payment.all
  end

  def signed_token(payload_json)
    Base64.urlsafe_encode64(Rails.application.message_verifier(:admin_api_cursor).generate(payload_json))
  end
end
