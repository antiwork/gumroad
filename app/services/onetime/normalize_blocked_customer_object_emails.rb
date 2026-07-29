# frozen_string_literal: true

# Normalizes stored blocked-customer addresses that carry an invisible character.
#
# Blocks recorded before we started normalizing hold the raw character in object_value. Incoming
# purchase emails are now cleaned before they are compared, so BlockedCustomerObject.comparable_email
# normalizes both sides of the comparison to keep those blocks matching. This task removes the need
# for that leniency on the stored side: it rewrites the rows so the blocklist holds the same clean
# form everything else does, which keeps the exact-match query fast and keeps the data honest for
# anyone reading it in support.
#
# Runs against the whole table in batches rather than a single UPDATE because blocked_customer_objects
# is large and a full scan on object_value has no index to lean on.
module Onetime
  class NormalizeBlockedCustomerObjectEmails
    BATCH_SIZE = 500

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      updated = 0

      BlockedCustomerObject.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch

        batch.each do |blocked_object|
          updated += 1 if normalize(blocked_object)
        end
      end

      puts "Normalized #{updated} blocked customer object row(s)"
      updated
    end

    private
      def normalize(blocked_object)
        clean_object_value = normalized_email_for(blocked_object)
        clean_buyer_email = if blocked_object.buyer_email.present?
          InvisibleCharacters.normalize_email(blocked_object.buyer_email)
        end

        changes = {}
        changes[:object_value] = clean_object_value if clean_object_value && clean_object_value != blocked_object.object_value
        changes[:buyer_email] = clean_buyer_email if clean_buyer_email && clean_buyer_email != blocked_object.buyer_email
        return false if changes.empty?

        # update_columns skips validation and callbacks deliberately: some of these rows hold a
        # fingerprint rather than an email, and a row whose OTHER column is invalid for an unrelated
        # reason must not stop us cleaning this one. There is nothing to observe here beyond the
        # bytes changing.
        blocked_object.update_columns(changes)
        puts "BlockedCustomerObject #{blocked_object.id}: #{changes.keys.join(', ')} normalized"
        true
      end

      # Only email rows carry an address in object_value; a fingerprint must be left exactly as it is.
      def normalized_email_for(blocked_object)
        return unless blocked_object.object_type == BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email]
        return if blocked_object.object_value.blank?

        InvisibleCharacters.normalize_email(blocked_object.object_value)
      end
  end
end
