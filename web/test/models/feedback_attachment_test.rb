# frozen_string_literal: true

require 'test_helper'

class FeedbackAttachmentTest < ActiveSupport::TestCase
  PNG = "\x89PNG\r\n\x1a\n#{'0' * 20}".b

  setup do
    Current.tenant = tenants(:default_tenant)
    @feedback = AgentFeedback.create!(kind: 'bug', summary: 'Broken', source: 'app')
  end

  teardown { Current.reset }

  test 'text attachments are capped and one per kind' do
    FeedbackAttachment.create!(agent_feedback: @feedback, kind: 'server_log', text_body: 'ok')
    assert_not FeedbackAttachment.new(agent_feedback: @feedback, kind: 'server_log', text_body: 'again').valid?
    big = FeedbackAttachment.new(agent_feedback: @feedback, kind: 'js_errors', text_body: 'x' * (FeedbackAttachment::TEXT_LIMITS['js_errors'] + 1))
    assert_not big.valid?
  end

  test 'clip cuts at the limit and drops control characters' do
    clipped = FeedbackAttachment.clip('client_context', "a\u0000b\n#{'é' * 10_000}")
    assert_operator clipped.bytesize, :<=, FeedbackAttachment::TEXT_LIMITS['client_context']
    assert clipped.valid_encoding?
    assert_not_includes clipped, "\u0000"
  end

  test 'screenshots must be PNG or JPEG bytes' do
    assert FeedbackAttachment.new(agent_feedback: @feedback, kind: 'screenshot', content_type: 'image/png', binary_body: PNG).valid?
    assert_not FeedbackAttachment.new(agent_feedback: @feedback, kind: 'screenshot', content_type: 'image/png', binary_body: '<svg onload=x>'.b).valid?
    assert_equal 'image/png', FeedbackAttachment.image_type(PNG)
    assert_equal 'image/jpeg', FeedbackAttachment.image_type("\xFF\xD8\xFFabc".b)
  end

  test 'only administrators may view attachments' do
    admin = users(:regular_user)
    assert FeedbackAttachment.viewable_by?(admin)
    assert FeedbackAttachment.viewable_by?(User.new(role: 'super_admin', active: true))
    %w[manager cashier reader reporting employee inventory_employee shift_leader].each do |role|
      assert_not FeedbackAttachment.viewable_by?(User.new(role: role, active: true)), role
    end
    assert_not FeedbackAttachment.viewable_by?(nil)
    assert_not FeedbackAttachment.viewable_by?(User.new(role: 'admin', active: false))
  end

  test 'deleting the feedback removes its attachments' do
    FeedbackAttachment.create!(agent_feedback: @feedback, kind: 'server_log', text_body: 'ok')
    assert_difference('FeedbackAttachment.count', -1) { @feedback.destroy }
  end
end
