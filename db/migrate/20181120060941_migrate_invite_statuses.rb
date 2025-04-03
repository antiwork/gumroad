# frozen_string_literal: true

class MigrateInviteStatuses < ActiveRecord::Migration
  def up
    Invite.where(invite_state: "paid_out").update_all(invite_state: "upgraded_to_pro")
    Invite.where(invite_state: "made_sale").update_all(invite_state: "signed_up")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
