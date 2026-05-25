# frozen_string_literal: true

require "test_helper"

class Helper::UnblockEmailServiceTest < ActiveSupport::TestCase
  include ActionView::Helpers::TextHelper

  setup do
    @conversation_id = "123"
    @email_id = "456"
    @email = "sam-#{SecureRandom.hex(3)}@example.com"
    @service = Helper::UnblockEmailService.new(conversation_id: @conversation_id, email_id: @email_id, email: @email)

    # Fixture user matching email so any callers referencing find_by(email:) succeed
    @buyer = users(:basic_user)
    @buyer.update_columns(email: @email)

    Feature.activate(:helper_unblock_emails)
    Feature.deactivate(:auto_reply_for_blocked_emails_in_helper)

    # Stub Helper::Client + EmailSuppressionManager via class-level method overrides.
    # Capture original UnboundMethods so teardown can restore them — using
    # `remove_method` would strip the real implementations (these are defined
    # directly on the classes) and leak NoMethodError into sibling tests.
    @client_calls = []
    cc = @client_calls
    @orig_helper_methods = {}
    [:add_note, :send_reply, :close_conversation].each do |m|
      @orig_helper_methods[m] = Helper::Client.instance_method(m) if Helper::Client.method_defined?(m)
    end
    Helper::Client.define_method(:add_note) do |**kwargs|
      cc << [:add_note, kwargs]
      true
    end
    Helper::Client.define_method(:send_reply) do |**kwargs|
      cc << [:send_reply, kwargs]
      true
    end
    Helper::Client.define_method(:close_conversation) do |**kwargs|
      cc << [:close_conversation, kwargs]
      true
    end
    @suppression_unblock_value = true
    @suppression_reasons = {}
    sup_unblock = -> { @suppression_unblock_value }
    sup_reasons = -> { @suppression_reasons }
    @orig_esm_methods = {}
    [:unblock_email, :reasons_for_suppression].each do |m|
      @orig_esm_methods[m] = EmailSuppressionManager.instance_method(m) if EmailSuppressionManager.method_defined?(m)
    end
    EmailSuppressionManager.define_method(:unblock_email) { sup_unblock.call }
    EmailSuppressionManager.define_method(:reasons_for_suppression) { sup_reasons.call }
  end

  teardown do
    [:add_note, :send_reply, :close_conversation].each do |m|
      if (orig = @orig_helper_methods && @orig_helper_methods[m])
        Helper::Client.define_method(m, orig)
      elsif Helper::Client.instance_methods(false).include?(m)
        Helper::Client.remove_method(m)
      end
    end
    [:unblock_email, :reasons_for_suppression].each do |m|
      if (orig = @orig_esm_methods && @orig_esm_methods[m])
        EmailSuppressionManager.define_method(m, orig)
      elsif EmailSuppressionManager.instance_methods(false).include?(m)
        EmailSuppressionManager.remove_method(m)
      end
    end
    Feature.deactivate(:helper_unblock_emails)
    Feature.deactivate(:auto_reply_for_blocked_emails_in_helper)
  end

  def find_calls(name)
    @client_calls.select { |c| c.first == name }
  end

  test "returns nil when feature is not active" do
    Feature.deactivate(:helper_unblock_emails)
    assert_nil @service.process
  end

  test "blocked by gumroad: unblocks the PlatformBlock email and drafts a reply when not auto-replying" do
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: @email)

    @service.process

    refute PlatformBlock.email.active.find_by(object_value: @email).present?
    sends = find_calls(:send_reply)
    assert_equal 1, sends.length
    assert_equal @conversation_id, sends.first.last[:conversation_id]
    assert_equal true, sends.first.last[:draft]
    assert_equal @email_id, sends.first.last[:response_to]
    assert_includes sends.first.last[:message], "Happy to help today"
    assert @service.replied?
  end

  test "blocked by gumroad: auto-replies and closes the conversation when feature is active" do
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: @email)
    Feature.activate(:auto_reply_for_blocked_emails_in_helper)

    @service.process

    sends = find_calls(:send_reply)
    closes = find_calls(:close_conversation)
    assert_equal 1, sends.length
    assert_nil sends.first.last[:draft]
    assert_includes sends.first.last[:message], "Happy to help today"
    assert_equal 1, closes.length
    assert_equal @conversation_id, closes.first.last[:conversation_id]
  end

  test "suppressed by sendgrid: adds note when reasons for suppression are present" do
    @suppression_reasons = {
      gumroad: [{ list: :bounces, reason: "Bounced reason 1" }, { list: :spam_reports, reason: "Email was reported as spam" }],
      creators: [{ list: :bounces, reason: "Bounced reason 2" }]
    }

    @service.process

    notes = find_calls(:add_note)
    assert_equal 1, notes.length
    msg = notes.first.last[:message]
    assert_includes msg, "Subuser: gumroad, List: bounces, Reason: Bounced reason 1"
    assert_includes msg, "Subuser: gumroad, List: spam_reports, Reason: Email was reported as spam"
    assert_includes msg, "Subuser: creators, List: bounces, Reason: Bounced reason 2"
  end

  test "suppressed by sendgrid: drafts a reply when auto-reply feature is inactive" do
    @service.process
    sends = find_calls(:send_reply)
    assert_equal 1, sends.length
    assert_equal true, sends.first.last[:draft]
    assert_includes sends.first.last[:message], "stopped sending you emails"
    assert @service.replied?
  end

  test "suppressed by sendgrid: auto-replies and closes the conversation when feature is active" do
    Feature.activate(:auto_reply_for_blocked_emails_in_helper)
    @service.process
    sends = find_calls(:send_reply)
    closes = find_calls(:close_conversation)
    assert_equal 1, sends.length
    assert_nil sends.first.last[:draft]
    assert_equal 1, closes.length
    assert @service.replied?
  end

  test "suppressed by sendgrid: doesn't send a reply when email is not in suppression lists" do
    @suppression_unblock_value = false
    @service.process
    assert_empty find_calls(:send_reply)
  end

  test "blocked by creator: drafts a reply" do
    @suppression_unblock_value = false
    other_seller = users(:another_seller)
    BlockedCustomerObject.block_email!(email: @email, seller_id: other_seller.id)

    @service.process

    sends = find_calls(:send_reply)
    assert_equal 1, sends.length
    assert_equal true, sends.first.last[:draft]
    assert_includes sends.first.last[:message], "a creator has blocked you"
  end
end
