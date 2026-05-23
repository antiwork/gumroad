# frozen_string_literal: true

require "test_helper"

class AnnualPayoutExportWorkerTest < ActiveSupport::TestCase
  self.described_class = AnnualPayoutExportWorker


  context_ AnnualPayoutExportWorker do
  context_ ".perform" do
      let!(:year) { 2019 }

      before do
        @user = create(:user)
      end

  context_ "when send_email argument is true" do
  test "sends an email to the creator" do
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 100)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year, true)
          end.to change { ActionMailer::Base.deliveries.count }.by(1)
          .and change { @user.reload.annual_reports.count }.by(1)

          mail = ActionMailer::Base.deliveries.last
          expect(mail.body.encoded).to include("In 2019 you made $100 on Gumroad.")
          expect(mail.body.encoded).to include("Good luck in 2020!")
        end

  test "does not send an email if payout amount is zero" do
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 0)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year, true)
          end.to change { ActionMailer::Base.deliveries.count }.by(0)
          .and change { @user.reload.annual_reports.count }.by(0)
        end

  test "does not send an email if payout amount is negative" do
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: -100)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year, true)
          end.to change { ActionMailer::Base.deliveries.count }.by(0)
          .and change { @user.reload.annual_reports.count }.by(0)
        end

  test "sends an email with link" do
          allow_any_instance_of(ActiveStorage::Blob).to receive(:url).and_return("http://gumroad.com")
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 100)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year, true)
          end.to change { ActionMailer::Base.deliveries.count }.by(1)
          .and change { @user.reload.annual_reports.count }.by(1)
          mail = ActionMailer::Base.deliveries.last
          expect(mail.body.encoded).to include("In 2019 you made $100 on Gumroad.")
          expect(mail.body.encoded).to include("Good luck in 2020!")
          expect(mail.body.encoded).to include("Please click this link ( http://gumroad.com ) to download")
        end

  test "fetches export data from Exports::Payouts::Annual" do
          exports_double = double
          expect(exports_double).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 100)
          expect(Exports::Payouts::Annual).to receive(:new).with(user: @user, year:).and_return(exports_double)
          AnnualPayoutExportWorker.new.perform(@user.id, year, true)
        end

  test "closes the tempfile after sending an email" do
          tempfile = temp_csv_file
          exports_double = double
          expect(exports_double).to receive(:perform).and_return(csv_file: tempfile, total_amount: 100)
          expect(Exports::Payouts::Annual).to receive(:new).with(user: @user, year:).and_return(exports_double)
          AnnualPayoutExportWorker.new.perform(@user.id, year, true)
          expect(tempfile.closed?).to eq(true)
        end

  test "does not create a new annual report for user if it already exists" do
          @user = create(:user, :with_annual_report, year:)

          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 0)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year, true)
          end.to change { @user.reload.annual_reports.count }.by(0)
        end
      end

  context_ "when send_email argument is false" do
  test "does not send an email to the creator and creates an annual report for user" do
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 100)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year)
          end.to change { ActionMailer::Base.deliveries.count }.by(0)
          .and change { @user.reload.annual_reports.count }.by(1)
        end

  test "does create an annual report for user if payout amount is zero" do
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 0)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year)
          end.to change { @user.reload.annual_reports.count }.by(0)
        end

  test "does not create an annual report for user if payout amount is negative" do
          allow_any_instance_of(Exports::Payouts::Annual).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: -100)
          expect do
            AnnualPayoutExportWorker.new.perform(@user.id, year)
          end.to change { @user.reload.annual_reports.count }.by(0)
        end

  test "fetches export data from Exports::Payouts::Annual" do
          exports_double = double
          expect(exports_double).to receive(:perform).and_return(csv_file: temp_csv_file, total_amount: 100)
          expect(Exports::Payouts::Annual).to receive(:new).with(user: @user, year:).and_return(exports_double)
          AnnualPayoutExportWorker.new.perform(@user.id, year)
        end

  test "closes the tempfile after sending an email" do
          tempfile = temp_csv_file
          exports_double = double
          expect(exports_double).to receive(:perform).and_return(csv_file: tempfile, total_amount: 100)
          expect(Exports::Payouts::Annual).to receive(:new).with(user: @user, year:).and_return(exports_double)
          AnnualPayoutExportWorker.new.perform(@user.id, year)
          expect(tempfile.closed?).to eq(true)
        end
      end

      private
        def temp_csv_file
          tempfile = Tempfile.new
          CSV.open(tempfile, "wb") { |csv| 10.times { csv << ["Some", "CSV", "Data"] } }
          tempfile.rewind
          tempfile
        end
    end
  end
end
