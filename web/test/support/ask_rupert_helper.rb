# frozen_string_literal: true

# Shared setup for Ask Rupert tests: people with different roles in the default
# workspace, and a stand-in model that answers from a script instead of a service.
module AskRupertHelper
  # Answers in order from a list; a string is the reply, an exception is raised as the failure.
  class ScriptedProvider
    attr_reader :calls

    def initialize(replies, name: 'opencode', cloud: true)
      @replies = replies.dup
      @name = name
      @cloud = cloud
      @calls = []
    end

    def name = @name
    def cloud? = @cloud
    def configured? = true
    def model = 'scripted-model'

    def complete(system:, messages:)
      @calls << { system: system, messages: messages }
      step = @replies.shift || 'Done.'
      raise step if step.is_a?(Exception)

      yield step if block_given?
      AskRupert::Providers::Reply.new(text: step, tokens_in: 100, tokens_out: 20, provider: name, model: model)
    end
  end

  def person(role, email: nil)
    Current.tenant = tenants(:default_tenant)
    User.create!(tenant: tenants(:default_tenant), email: email || "#{role}-#{SecureRandom.hex(3)}@example.com", role: role, password: 'password', name: role.to_s.humanize)
  end

  # A question waiting for its reply, as the controller leaves it.
  def pending_turn(user, text)
    Current.tenant = user.tenant
    conversation = AskRupert::Conversation.create!(user: user)
    conversation.messages.create!(user: user, role: 'user', content: text)
    AskRupert::Usage.create!(user: user, outcome: 'pending')
    [conversation, conversation.messages.create!(user: user, role: 'assistant', status: 'pending')]
  end
end
