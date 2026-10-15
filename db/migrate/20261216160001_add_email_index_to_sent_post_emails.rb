# frozen_string_literal: true

class AddEmailIndexToSentPostEmails < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The only other index is (post_id, email), so erasing one recipient's rows
    # across every seller's posts scans the table. 191 matches idx_audience_on_email.
    #
    # if_not_exists so the pt-osc copy can be run out of band ahead of the deploy
    # instead of inside it (gumroad-private#1810).
    add_index :sent_post_emails, :email, name: "index_sent_post_emails_on_email", length: 191, if_not_exists: true
  end
end
