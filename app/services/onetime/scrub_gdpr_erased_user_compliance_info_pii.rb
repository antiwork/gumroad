# frozen_string_literal: true

# Before GdprDataErasureService learned to null the PII columns on compliance (KYC)
# records, an erasure only soft-deleted them — so users erased before that fix still
# have their legal name, date of birth, street address, and phone number sitting in
# plaintext in user_compliance_info rows. This task sweeps those historical erasures.
#
# Erased accounts are identifiable by the placeholder email the erasure service
# assigns ("deleted-<user id>@deleted.gumroad.com"); no other flow writes emails on
# that domain to the users table. The columns nulled here match the ones the service
# now nulls during erasure, so re-running this task is safe (it just re-nulls nils).
#
# Usage: Onetime::ScrubGdprErasedUserComplianceInfoPii.process
module Onetime
  class ScrubGdprErasedUserComplianceInfoPii
    BATCH_SIZE = 500

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      scrubbed_rows = 0

      erased_users.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        scrubbed_rows += UserComplianceInfo.where(user_id: batch.ids).update_all(
          full_name: nil,
          first_name: nil,
          last_name: nil,
          birthday: nil,
          street_address: nil,
          city: nil,
          state: nil,
          zip_code: nil,
          telephone_number: nil,
          json_data: nil,
          updated_at: Time.current,
        )
      end

      puts "Nulled PII columns on #{scrubbed_rows} user_compliance_info rows"
      scrubbed_rows
    end

    private
      def erased_users
        # Prefix LIKE so index_users_on_email can be used as a range scan.
        User.where("email LIKE ?", "deleted-%@#{GdprDataErasureService::ANONYMIZED_EMAIL_DOMAIN}")
      end
  end
end
