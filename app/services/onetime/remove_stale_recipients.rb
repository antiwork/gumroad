# frozen_string_literal: true

class Onetime::RemoveStaleRecipients
  def self.process
    # Process followers
    last_follower_id = $redis.get(last_follower_id_key)&.to_i || 0
    Follower.alive.where("id > ?", last_follower_id).find_each do |follower|
      if EmailEvent.stale_recipient?(follower.email)
        follower.mark_deleted!
        EmailEvent.mark_as_stale(follower.email, Time.current)
      end
      $redis.set(last_follower_id_key, follower.id)
    end

    # Process purchases
    last_purchase_id = $redis.get(last_purchase_id_key)&.to_i || 0
    Purchase.where("id > ?", last_purchase_id).where(can_contact: true).find_each do |purchase|
      if EmailEvent.stale_recipient?(purchase.email)
        begin
          purchase.update!(can_contact: false)
        rescue ActiveRecord::RecordInvalid
          Rails.logger.info "Could not update purchase (#{purchase.id}) with validations turned on. Unsubscribing the buyer without running validations."
          purchase.can_contact = false
          purchase.save(validate: false)
        end

        EmailEvent.mark_as_stale(purchase.email, Time.current)
      end
      $redis.set(last_purchase_id_key, purchase.id)
    end
  end

  private
    def self.last_follower_id_key
      "remove_stale_recipients_last_follower_id"
    end

    def self.last_purchase_id_key
      "remove_stale_recipients_last_purchase_id"
    end
end
