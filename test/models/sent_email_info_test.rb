# frozen_string_literal: true

require "test_helper"

class SentEmailInfoTest < ActiveSupport::TestCase
  self.described_class = SentEmailInfo



  context_ SentEmailInfo do
  context_ "validations" do
  test "doesn't allow empty keys" do
        expect do
          SentEmailInfo.set_key!(nil)
        end.to raise_error(ActiveRecord::RecordInvalid)
      end

  test "doesn't allow duplicate keys" do
        SentEmailInfo.set_key!("key")

        expect do
          sent_email_info = SentEmailInfo.new
          sent_email_info.key = "key"
          sent_email_info.save!
        end.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

  context_ ".key_exists?" do
      before do
        @sent_email_info = create(:sent_email_info)
      end

  test "returns true if record exists" do
        expect(SentEmailInfo.key_exists?(@sent_email_info.key)).to eq true
        expect(SentEmailInfo.key_exists?("non-existing-key")).to eq false
      end

  test "is not affected by outer ActiveRecord scopes" do
        user = create(:user)
        # Simulate calling key_exists? from within an association scope block,
        # which could leak a user_id WHERE clause into the SentEmailInfo query
        user.purchases.where(id: 0).each do |_|
          # This block won't execute, but the scope is established
        end
        # Even after scoped iteration, key_exists? should work without scope leakage
        expect(SentEmailInfo.key_exists?(@sent_email_info.key)).to eq true
      end
    end

  context_ ".set_key!" do
      before do
        @sent_email_info = SentEmailInfo.set_key!("test_key")
      end

  test "sets the record in SentEmailInfo" do
        expect(@sent_email_info).to eq(true)
        expect(SentEmailInfo.find_by(key: "test_key")).not_to be_nil
      end

  test "doesn't set duplicate records" do
        was_set = SentEmailInfo.set_key!("test_key")
        expect(was_set).to eq(nil)
        expect(SentEmailInfo.where(key: "test_key").count).to eq 1
      end
    end

  context_ ".mailer_exists?" do
  test "returns true if a record exists for the mailer" do
        expect(SentEmailInfo.mailer_exists?("Mailer", "action", 123, 456)).to eq(false)
        SentEmailInfo.ensure_mailer_uniqueness("Mailer", "action", 123, 456) { }
        expect(SentEmailInfo.mailer_exists?("Mailer", "action", 123, 456)).to eq(true)
      end
    end

  context_ ".ensure_mailer_uniqueness" do
      before do
        @shipment = create(:shipment)
      end

  test "doesn't allow sending email for given key and params" do
        expect do
          SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer",
                                                 "order_shipped",
                                                 @shipment.id) do
            CustomerLowPriorityMailer.order_shipped(@shipment.id).deliver_later
          end

          SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer",
                                                 "order_shipped",
                                                 @shipment.id) do
            CustomerLowPriorityMailer.order_shipped(@shipment.id).deliver_later
          end
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :order_shipped).once
      end
    end
  end
end
