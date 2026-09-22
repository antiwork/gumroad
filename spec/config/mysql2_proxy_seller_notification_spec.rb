# frozen_string_literal: true

require "spec_helper"

# ContactingCreatorMailer#notify is enqueued three seconds after the sale commits and rendered by a
# worker, whose reads land on a replica. These examples run against real primary/replica pools and
# assert the connection each statement was served by, not where it sat on the connected_to stack.
describe "mysql2 proxy seller notification routing" do
  include_context "real mysql2 proxy pools"

  before do
    primary_setup do
      create(:merchant_account, user: nil) unless MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    end
  end

  def expect_serving_pool(reads, pool, *tables)
    tables.each do |table|
      relevant = reads.select { |sql, _| sql.include?("`#{table}`") }
      expect(relevant).not_to be_empty
      expect(relevant.map(&:last).uniq).to eq([pool])
    end
  end

  # Quoted-printable wraps at 76 columns, which can land inside a rendered amount.
  def rendered(message)
    message.body.encoded.gsub(/=\r\n/, "")
  end

  it "renders a sale the replica has not received yet" do
    purchase = primary_setup { create(:purchase, full_name: "Routing Buyer") }
    expect(serving_pool).to eq("replica")

    message = nil
    reads = record_serving_reads { message = ContactingCreatorMailer.notify(purchase.id).message }

    expect_serving_pool(reads, "primary", "purchases", "links", "users")
    expect(message.to).to eq([primary_setup { purchase.seller.form_email }])
    expect(rendered(message)).to include("Routing Buyer")
    expect(serving_pool).to eq("replica")
  end

  it "reads the associations the template walks after the action from the primary" do
    purchase = primary_setup do
      create(:purchase, full_name: "Routing Tipper").tap { _1.create_tip!(value_cents: 1234) }
    end
    # Replicating these lets an unpinned render reach the template and drop the tip line silently.
    primary_setup { [purchase, purchase.link, purchase.seller].each { replicate_record(_1) } }

    message = nil
    reads = record_serving_reads { message = ContactingCreatorMailer.notify(purchase.id).message }

    expect_serving_pool(reads, "primary", "purchases", "tips")
    expect(rendered(message)).to include("Tip", "$12.34")
    expect(serving_pool).to eq("replica")
  end

  it "leaves the mailer's other actions offloading to the replica" do
    seller = primary_setup { create(:user) }
    replicate_record(seller)

    message = nil
    reads = record_serving_reads { message = ContactingCreatorMailer.remind(seller.id).message }

    expect_serving_pool(reads, "replica", "users", "purchases")
    expect(message.subject).to eq("Please add a payment account to Gumroad.")
  end
end
