# frozen_string_literal: true

namespace :team_chat do
  default_questions = [
    'How were sales yesterday?',
    'Anything low on stock I should know about?',
    'Are there any open alerts?',
    'Is sync healthy right now?',
    'Where do I approve timesheets?',
    'Make a task to recount the tea shelf tomorrow, high priority.'
  ].freeze

  desc 'Ask @rupert questions with the configured model and print answers, tools and timing. ' \
       'Nothing is kept (every run is rolled back). QUESTIONS="a|b" USER_EMAIL=... TENANT_ID=... ' \
       'Override the model with RUPERT_CHAT_PROVIDER / RUPERT_CHAT_MODEL / OLLAMA_URL.'
  task try: :environment do
    tenant = ENV['TENANT_ID'].present? ? Tenant.find(ENV['TENANT_ID']) : Tenant.where(status: 'active').first
    Current.tenant = tenant
    user = ENV['USER_EMAIL'].present? ? User.find_by!(email: ENV['USER_EMAIL'], tenant_id: tenant.id) : User.where(tenant_id: tenant.id, role: %w[admin super_admin], active: true).first
    Current.user = user
    config = TeamChat::ModelConfig.current
    questions = ENV['QUESTIONS'].present? ? ENV['QUESTIONS'].split('|').map(&:strip) : default_questions
    puts "Model: #{config.label} (engine #{config.engine}) · asking as #{user.display_name}"
    questions.each do |question|
      ActiveRecord::Base.transaction do
        room = TeamChat::Room.create!(name: "model-check-#{SecureRandom.hex(3)}", assistant_mode: 'all', created_by: user)
        message = room.messages.create!(user: user, body: question)
        reply = room.messages.create!(author_kind: 'assistant', status: 'pending', meta: { 'asked_by' => user.id, 'trigger_id' => message.id })
        TeamChat::Agent.new(reply, config: config).run
        reply.reload
        meta = reply.meta.to_h
        puts "\nQ: #{question}"
        puts "   #{meta['outcome']} in #{(meta['duration_ms'].to_i / 1000.0).round(1)}s · tools: #{Array(meta['tools']).join(', ').presence || 'none'} · " \
             "tokens #{meta['tokens_in']}/#{meta['tokens_out']}#{" · proposed: #{reply.actions_list.map { |action| action['summary'] }.join('; ')}" if reply.actions_list.any?}"
        puts reply.body.to_s.gsub(/^/, '   ')
        raise ActiveRecord::Rollback
      end
    end
  end
end
