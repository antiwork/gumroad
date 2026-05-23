# frozen_string_literal: true

require "test_helper"

class DropboxFilesPolicyTest < ActiveSupport::TestCase
  include PolicyAssertions

  ACTIONS = %i[create? index? cancel_upload?].freeze

  test "grants access to owner" do
    assert_policy_permits DropboxFilesPolicy, :dropbox_files, :named_seller, *ACTIONS
  end
  test "grants access to admin" do
    assert_policy_permits DropboxFilesPolicy, :dropbox_files, :admin_for_named_seller, *ACTIONS
  end
  test "grants access to marketing" do
    assert_policy_permits DropboxFilesPolicy, :dropbox_files, :marketing_for_named_seller, *ACTIONS
  end
  test "denies access to accountant" do
    refute_policy_permits DropboxFilesPolicy, :dropbox_files, :accountant_for_named_seller, *ACTIONS
  end
  test "denies access to support" do
    refute_policy_permits DropboxFilesPolicy, :dropbox_files, :support_for_named_seller, *ACTIONS
  end
end
