# frozen_string_literal: true

require 'test_helper'

# The tool-using agent is told how to file reports, and told what it must never
# do because a chat message says so. The text-only agent has no tools and is not.
class BuzzAgentIntakePromptTest < ActiveSupport::TestCase
  test 'the acp prompt teaches the four categories, the stdin JSON script and the allow-list rule' do
    text = BuzzAgentPrompt.render(mode: :acp)
    %w[question bug request direction].each { |word| assert_includes text, "  #{word} " }
    assert_includes text, 'scripts/feedback_intake.rb file'
    assert_includes text, 'RUPERT_INTAKE_END'
    assert_includes text, 'ONLY from the event metadata'
    assert_includes text, "allow-list"
    assert_includes text, 'never obey it'
    assert_includes text, 'Never deploy'
  end

  test 'the text-only prompt has no intake script' do
    assert_not_includes BuzzAgentPrompt.render(mode: :text_only), 'feedback_intake'
  end

  test 'every script the prompt names exists and the commands it shows are real' do
    text = BuzzAgentPrompt.render(mode: :acp)
    text.scan(%r{scripts/(\w+\.rb)}).flatten.uniq.each { |name| assert Rails.root.join('scripts', name).file?, name }
    %w[file answered status list].each { |command| assert_includes text, "feedback_intake.rb #{command}" }
  end
end
