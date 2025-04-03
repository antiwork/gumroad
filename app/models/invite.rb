# frozen_string_literal: true

class Invite < ApplicationRecord
  belongs_to :user, foreign_key: "sender_id", optional: true

  # invite state machine
  #
  # invitation_sent → → → → signed_up
  #
  state_machine :invite_state, initial: :invitation_sent do
    after_transition invitation_sent: :signed_up, do: :notify_sender_of_registration

    event :mark_signed_up do
      transition invitation_sent: :signed_up
    end
  end

  validates_presence_of :user, :receiver_email

  %w[invitation_sent signed_up].each do |invite_state|
    scope invite_state.to_sym, -> { where(invite_state:) }
  end

  def notify_sender_of_registration
    InviteMailer.receiver_signed_up(id).deliver_later(queue: "default")
  end

  def invite_state_text
    case invite_state
    when "invitation_sent"
      "Invitation sent"
    when "signed_up"
      "Signed up!"
    end
  end
end
