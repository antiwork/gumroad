# frozen_string_literal: true

# A storefront is a separately-branded "Gumroad" that lives under one account: the account (User)
# is the person — login, identity, payout details — while each storefront carries its own public
# name, username, and bio. This lets a creator run multiple brands that all pay out through the
# same account, instead of juggling separate accounts with duplicated bank details.
#
# v1 keeps this additive: the account's own username/profile keeps working unchanged as the first
# brand, and extra storefronts are created on top. Products are assigned to at most one storefront;
# unassigned products keep showing on the account's main profile.
class Storefront < ApplicationRecord
  include ExternalId, Deletable

  belongs_to :seller, class_name: "User"

  has_many :storefront_products, dependent: :destroy
  has_many :products, through: :storefront_products, source: :link

  validates :username, presence: true,
                       length: { minimum: 3, maximum: 20 },
                       exclusion: { in: DENYLIST },
                       # Same shape as account usernames: lower case letters and numbers only,
                       # at least one letter — the username becomes a subdomain, so the rules
                       # must match what account usernames allow.
                       format: { with: /\A[a-z0-9]*[a-z][a-z0-9]*\z/, message: "has to contain at least one letter and may only contain lower case letters and numbers." }
  validates :username, uniqueness: { case_sensitive: true, conditions: -> { alive } }, if: :username_changed?
  validate :username_not_taken_by_an_account, if: :username_changed?
  validates :name, length: { maximum: 100 }
  validates :bio, length: { maximum: 3_000 }

  def self.find_by_username(username, scope: alive)
    username = username.to_s
    return if username.blank?

    # Hostnames use hyphens where usernames use underscores (same convention as account
    # subdomains), so convert before looking up.
    scope.find_by(username: username.tr("-", "_"))
  end

  def subdomain
    Subdomain.from_username(username)
  end

  def subdomain_with_protocol
    "#{PROTOCOL}://#{subdomain}"
  end

  def profile_url
    subdomain_with_protocol
  end

  private
    # Storefront usernames and account usernames share one public namespace — both resolve at
    # <username>.gumroad.com — so a storefront can never claim a handle an account already uses.
    def username_not_taken_by_an_account
      return if username.blank?

      errors.add(:username, "is already taken.") if User.exists?(username:)
    end
end
