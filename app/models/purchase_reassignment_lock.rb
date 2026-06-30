# frozen_string_literal: true

# Marks a purchase as under review so Purchase::ReassignByEmailService refuses to
# move it between accounts. Lives in its own table rather than as a column on the
# (too-large-to-alter) purchases table; a row's presence is the lock.
class PurchaseReassignmentLock < ApplicationRecord
  belongs_to :purchase

  validates :purchase, uniqueness: true
end
