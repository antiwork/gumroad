# frozen_string_literal: true

class ExportPayoutData
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def initialize
    @tempfiles_to_cleanup = []
  end

  def perform(payment_ids, recipient_user_id)
    payment_ids = Array.wrap(payment_ids)
    payouts = generate_payouts(payment_ids)

    return if payouts.empty?
    return unless all_from_same_seller?(payouts)

    filename, extension, tempfile =
      if payouts.size == 1
        payout = payouts.first
        ["#{payout[:filename]}.#{payout[:extension]}", payout[:extension], payout[:tempfile]]
      else
        ["Payouts.zip", "zip", create_zip_archive(payouts)]
      end

    ContactingCreatorMailer.payout_data(filename, extension, tempfile, recipient_user_id).deliver_now
  ensure
    cleanup_tempfiles
  end

  private
    def create_tempfile(*args, **kwargs)
      Tempfile.new(*args, **kwargs).tap do |tempfile|
        @tempfiles_to_cleanup << tempfile
      end
    end

    def cleanup_tempfiles
      @tempfiles_to_cleanup.each do |tempfile|
        tempfile.close
        tempfile.unlink
      end
    end

    def create_zip_archive(payouts)
      zip_file = create_tempfile(["payouts", ".zip"])

      Zip::File.open(zip_file.path, Zip::File::CREATE) do |zip|
        filename_registry = FilenameRegistry.new

        payouts.each do |payout|
          unique_filename = filename_registry.generate_unique_name(payout[:filename], payout[:extension])
          zip.add(unique_filename, payout[:tempfile].path)
        end
      end

      # Reopen the file as it was written to in a separate stream.
      zip_file.open
      zip_file.rewind
      zip_file
    end

    def generate_payouts(payment_ids)
      payouts = []

      Payment.where(id: payment_ids).find_each do |payment|
        tempfile = create_tempfile(["payout", ".csv"])

        content = Exports::Payouts::Csv.new(payment: payment).perform
        tempfile.write(content)
        tempfile.rewind

        payouts << {
          tempfile:,
          filename: "Payout of #{payment.created_at.to_date}",
          extension: "csv",
          seller_id: payment.user_id
        }
      end

      payouts
    end

    def all_from_same_seller?(payouts)
      payouts.map { |payout| payout[:seller_id] }.uniq.size == 1
    end

    class FilenameRegistry
      def initialize
        @existing_filenames = Set.new
      end

      def generate_unique_name(filename, extension)
        find_unique_filename(filename, extension).tap do |unique_filename|
          @existing_filenames << unique_filename
        end
      end

      private
        def find_unique_filename(filename, extension, index_suffix = 0)
          candidate = "#{filename}#{index_suffix > 0 ? " (#{index_suffix})" : ""}.#{extension}"

          if @existing_filenames.include?(candidate)
            find_unique_filename(filename, extension, index_suffix + 1)
          else
            candidate
          end
        end
    end
end
