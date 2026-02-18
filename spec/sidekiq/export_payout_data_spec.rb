# frozen_string_literal: true

describe ExportPayoutData do
  describe "#perform" do
    let(:seller) { create(:named_seller) }

    let(:payment1) { create(:payment, user: seller, created_at: Time.zone.now) }
    let(:payment2) { create(:payment, user: seller, created_at: 7.days.ago) }

    let(:payment_ids) { [payment1.id, payment2.id] }

    let(:csv_data1) { "Payment1,CSV,data\n" }
    let(:csv_data2) { "Payment2,CSV,data\n" }

    before do
      allow(Exports::Payouts::Csv).to receive(:new).with(payment: payment1).and_return(double(perform: csv_data1))
      allow(Exports::Payouts::Csv).to receive(:new).with(payment: payment2).and_return(double(perform: csv_data2))
    end

    it "generates CSV files for each payment" do
      expect(Exports::Payouts::Csv).to receive(:new).with(payment: payment1)
      expect(Exports::Payouts::Csv).to receive(:new).with(payment: payment2)

      ExportPayoutData.new.perform(payment_ids, seller.id)
    end

    it "sends an email with a zip file when multiple payments are provided" do
      mail_double = instance_double(ActionMailer::MessageDelivery)
      expect(mail_double).to receive(:deliver_now)

      expect(ContactingCreatorMailer).to receive(:payout_data) do |filename, extension, tempfile, recipient_id|
        expect(filename).to eq("Payouts.zip")
        expect(extension).to eq("zip")
        expect(tempfile.size).not_to eq(0)
        expect(recipient_id).to eq(seller.id)

        Zip::File.open(tempfile.path) do |zip|
          expect(zip.entries.map(&:name)).to contain_exactly(
            "Payout of #{payment1.created_at.to_date}.csv",
            "Payout of #{payment2.created_at.to_date}.csv"
          )

          expect(zip.read("Payout of #{payment1.created_at.to_date}.csv")).to eq(csv_data1)
          expect(zip.read("Payout of #{payment2.created_at.to_date}.csv")).to eq(csv_data2)
        end

        mail_double
      end

      ExportPayoutData.new.perform(payment_ids, seller.id)
    end

    it "sends an email with a single CSV file when only one payment is provided" do
      mail_double = instance_double(ActionMailer::MessageDelivery)
      expect(mail_double).to receive(:deliver_now)

      expect(ContactingCreatorMailer).to receive(:payout_data) do |filename, extension, tempfile, recipient_id|
        expect(filename).to eq("Payout of #{payment1.created_at.to_date}.csv")
        expect(extension).to eq("csv")
        expect(tempfile.size).not_to eq(0)
        expect(recipient_id).to eq(seller.id)
        expect(tempfile.read).to eq(csv_data1)

        mail_double
      end

      ExportPayoutData.new.perform([payment1.id], seller.id)
    end

    it "handles a single ID passed as a non-array" do
      mail_double = instance_double(ActionMailer::MessageDelivery)
      expect(mail_double).to receive(:deliver_now)

      expect(ContactingCreatorMailer).to receive(:payout_data) do |filename, extension, tempfile, recipient_id|
        expect(filename).to eq("Payout of #{payment1.created_at.to_date}.csv")
        expect(extension).to eq("csv")
        expect(tempfile.size).not_to eq(0)
        expect(recipient_id).to eq(seller.id)
        mail_double
      end

      ExportPayoutData.new.perform(payment1.id, seller.id)
    end

    it "does nothing if no payments are found" do
      expect(ContactingCreatorMailer).not_to receive(:payout_data)

      ExportPayoutData.new.perform([999999], seller.id)
    end

    it "does nothing if payments are from different sellers" do
      another_seller = create(:user)
      payment3 = create(:payment, user: another_seller)

      allow(Exports::Payouts::Csv).to receive(:new).with(payment: payment3).and_return(double(perform: "Payment3,CSV,data\n"))

      expect(ContactingCreatorMailer).not_to receive(:payout_data)

      ExportPayoutData.new.perform([payment1.id, payment3.id], seller.id)
    end

    context "with duplicate filenames" do
      let(:payment1) { create(:payment, user: seller, created_at: Time.zone.now) }
      let(:payment2) { create(:payment, user: seller, created_at: Time.zone.now) }

      it "creates unique filenames in the zip archive" do
        mail_double = instance_double(ActionMailer::MessageDelivery)
        expect(mail_double).to receive(:deliver_now)

        expect(ContactingCreatorMailer).to receive(:payout_data) do |filename, extension, tempfile, recipient_id|
          expect(filename).to eq("Payouts.zip")
          expect(extension).to eq("zip")
          expect(tempfile.size).not_to eq(0)

          Zip::File.open(tempfile.path) do |zip|
            expect(zip.entries.map(&:name)).to contain_exactly(
              "Payout of #{payment1.created_at.to_date}.csv",
              "Payout of #{payment1.created_at.to_date} (1).csv",
            )
          end

          mail_double
        end

        ExportPayoutData.new.perform(payment_ids, seller.id)
      end
    end
  end
end
