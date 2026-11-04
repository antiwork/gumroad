# frozen_string_literal: true

class AddPingSigningSecretToUsers < ActiveRecord::Migration[8.1]
  # Nullable, and nullable forever: the column's presence is what turns signing on for one seller, so
  # every existing account — and every account that never opts in — stays unsigned. Rotating overwrites
  # the value in place; turning signing off sets it back to NULL.
  #
  # Stored in the clear, like the oauth application secrets next to it: HMAC needs the key itself to
  # sign, so a digest cannot stand in for it, and the seller has to read the same value to verify.
  def change
    add_column :users, :ping_signing_secret, :string
  end
end
