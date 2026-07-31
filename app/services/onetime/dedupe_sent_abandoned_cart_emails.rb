# frozen_string_literal: true

# Deletes duplicate (cart_id, installment_id) rows, keeping the oldest, so the unique
# index in AddUniqueIndexToSentAbandonedCartEmails can build. Run before that migration.
module Onetime
  class DedupeSentAbandonedCartEmails
    def self.process
      new.process
    end

    def process
      duplicate_pairs = SentAbandonedCartEmail
        .group(:cart_id, :installment_id)
        .having("COUNT(*) > 1")
        .pluck(:cart_id, :installment_id)

      puts "Found #{duplicate_pairs.size} duplicated (cart_id, installment_id) pairs"

      duplicate_pairs.each do |cart_id, installment_id|
        ReplicaLagWatcher.watch
        ids = SentAbandonedCartEmail.where(cart_id:, installment_id:).order(id: :asc).ids
        deleted = SentAbandonedCartEmail.where(id: ids.drop(1)).delete_all
        puts "cart_id=#{cart_id} installment_id=#{installment_id}: kept #{ids.first}, deleted #{deleted}"
      end
    end
  end
end
