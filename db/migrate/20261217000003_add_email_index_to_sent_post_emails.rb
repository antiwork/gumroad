# frozen_string_literal: true

class AddEmailIndexToSentPostEmails < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # GDPR erasure looks rows up by email alone, across every post. Full length rather than a
    # prefix, so that lookup is answered from the index without reading the rows.
    #
    # if_not_exists so the pt-osc copy can be run out of band — on a table this size it cannot
    # ride a deploy (gumroad-private#1810).
    add_index :sent_post_emails, :email, if_not_exists: true
  end
end
