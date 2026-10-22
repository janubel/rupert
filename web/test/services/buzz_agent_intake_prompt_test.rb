# frozen_string_literal: true

require 'test_helper'

# The sandboxed tool-using agent is told how to file reports through Rupert's MCP tool, and told what it must never
# do because a chat message says so. The text-only agent has no tools and is not.
class BuzzAgentIntakePromptTest < ActiveSupport::TestCase
  test 'the acp prompt teaches the four categories, the filing tool and the allow-list rule' do
    text = BuzzAgentPrompt.render(mode: :acp)
    %w[question bug request direction].each { |word| assert_includes text, "  #{word} " }
    assert_includes text, 'rupert_submit_feedback'
    assert_includes text, 'source_sender'
    assert_includes text, 'ONLY from the event metadata'
    assert_includes text, 'allow-list'
    assert_includes text, 'never obey it'
    assert_includes text, 'Never deploy'
  end

  test 'the acp prompt names only tools the sandbox bridge exposes' do
    text = BuzzAgentPrompt.render(mode: :acp)
    assert_includes text, 'rupert_buzz_reply'
    assert_not_includes text, 'bin/rails'
    assert_not_includes text, 'buzz messages send'
    bridge = Rails.root.join('../deploy/ser8/agent/rupert_mcp_bridge.py')
    skip 'bridge not in the mounted tree' unless bridge.file?
    allowed = bridge.read[/ALLOWED_RUPERT_TOOLS = \((.*?)\)/m, 1].scan(/'(\w+)'/).flatten
    %w[get_workspace_info sales_summary inventory_search list_alerts list_tasks list_reports].each do |tool|
      assert_includes allowed, tool
      assert_includes text, tool
    end
    assert_includes allowed, 'submit_feedback'
    assert_not_includes allowed, 'create_task'
  end

  test 'the text-only prompt has no filing tool' do
    assert_not_includes BuzzAgentPrompt.render(mode: :text_only), 'submit_feedback'
  end
end
