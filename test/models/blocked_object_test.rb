# frozen_string_literal: true

require "test_helper"

class BlockedObjectTest < ActiveSupport::TestCase
  self.described_class = BlockedObject



  context_ BlockedObject do
  context_ ".block!" do
  context_ "when blocked object doesn't exist" do
  test "creates a new blocked object record" do
          count = BlockedObject.count
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "123.456.789.0", nil, expires_in: 1.hour)
          expect(BlockedObject.all.count).to eq count + 1
          expect(BlockedObject.find_by(object_value: "123.456.789.0").blocked?).to be(true)
        end
      end

  context_ "when blocked object exists" do
  test "updates the existing record" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.123.456.0", nil, expires_in: 1.hour)
          BlockedObject.unblock!("789.123.456.0")
          count = BlockedObject.count
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.123.456.0", nil, expires_in: 1.hour)
          expect(BlockedObject.count).to eq count
        end
      end

  context_ "when :expires_in is present" do
  test "blocks and sets the expiration date appropriately" do
          count = BlockedObject.active.count
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.124.456.0", nil, expires_in: 3.days)
          expect(BlockedObject.active.count).to eq count + 1
          expect(BlockedObject.last.expires_at).not_to be(nil)
        end

  test "is not active after the expiration date" do
          count = BlockedObject.active.count
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "789.125.456.0", nil, expires_in: -3.days)
          expect(BlockedObject.active.count).to eq count
        end
      end
    end

  context_ "#unblock!" do
      let(:blocked_object) do
        ip_address = "157.45.09.212"
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], ip_address, nil, expires_in: 1.hour)

        BlockedObject.find_by(object_value: ip_address)
      end

  test "unblocks the blocked object" do
        expect(blocked_object.blocked?).to be(true)

        blocked_object.unblock!

        expect(blocked_object.blocked?).to be(false)
      end
    end

  context_ ".unblock!" do
  context_ "when it isn't there" do
  test "fails silently" do
          expect(BlockedObject.find_by(object_value: "lol")).to be(nil)
          expect(-> { BlockedObject.unblock!("lol") }).not_to raise_error
        end
      end

  context_ "when it is there" do
  test "unblocks" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "456.789.123.0", nil, expires_in: 1.hour)
          expect(BlockedObject.find_by(object_value: "456.789.123.0").blocked?).to be(true)
          BlockedObject.unblock!("456.789.123.0")
          expect(BlockedObject.find_by(object_value: "456.789.123.0").blocked?).to be(false)
        end
      end
    end

  context_ ".charge_processor_fingerprint" do
      let(:email) { "paypal@example.com" }

      before do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], email, nil)
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], email, nil)
      end

  test "returns the list of blocked objects with object_type 'charge_processor_fingerprint'" do
        expect(BlockedObject.charge_processor_fingerprint.count).to eq 1

        blocked_object = BlockedObject.charge_processor_fingerprint.first
        expect(blocked_object.object_type).to eq BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint]
        expect(blocked_object.object_value).to eq email
      end
    end

  context_ "expires_at validation" do
  context_ "when object_type is ip_address" do
        let(:object_type) { BLOCKED_OBJECT_TYPES[:ip_address] }
        let(:object_value) { "192.168.1.1" }

  context_ "when blocked_at is present" do
  test "is invalid without expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: Time.current
            )

            expect(blocked_object).not_to be_valid
            expect(blocked_object.errors[:expires_at]).to include("can't be blank")
          end

  test "is valid with expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: Time.current,
              expires_at: Time.current + 1.hour
            )

            expect(blocked_object).to be_valid
          end
        end

  context_ "when blocked_at is nil" do
  test "is valid without expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: nil,
              expires_at: nil
            )

            expect(blocked_object).to be_valid
          end

  test "is valid with expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: nil,
              expires_at: Time.current + 1.hour
            )

            expect(blocked_object).to be_valid
          end
        end
      end

  context_ "when object_type is NOT ip_address" do
        let(:object_type) { BLOCKED_OBJECT_TYPES[:email] }
        let(:object_value) { "test@example.com" }

  context_ "when blocked_at is present" do
  test "is valid without expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: Time.current,
              expires_at: nil
            )

            expect(blocked_object).to be_valid
          end

  test "is valid with expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: Time.current,
              expires_at: Time.current + 1.hour
            )

            expect(blocked_object).to be_valid
          end
        end

  context_ "when blocked_at is nil" do
  test "is valid without expires_at" do
            blocked_object = BlockedObject.new(
              object_type: object_type,
              object_value: object_value,
              blocked_at: nil,
              expires_at: nil
            )

            expect(blocked_object).to be_valid
          end
        end
      end
    end
  end
end
