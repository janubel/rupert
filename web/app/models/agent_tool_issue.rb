# frozen_string_literal: true

# Automatic "struggle" signal: one counter row per tenant, MCP tool and error
# kind, bumped whenever an assistant's tool call fails or is denied. Owners
# see where assistants get stuck without anyone writing a report.
class AgentToolIssue < ApplicationRecord
  include TenantScoped

  ERROR_KINDS = {
    'denied' => 'Permission denied', 'invalid_arguments' => 'Invalid arguments', 'unknown_tool' => 'Unknown tool',
    'not_found' => 'Not found', 'tool_error' => 'Tool could not answer', 'internal_error' => 'Unexpected failure'
  }.freeze

  validates :tenant_id, :tool_name, :error_kind, :first_seen_at, :last_seen_at, presence: true
  validates :error_kind, inclusion: { in: ERROR_KINDS.keys }

  # Never raises: a failed counter must not change the assistant's answer.
  def self.record!(tool_name:, error_kind:, message:, token:)
    now = Time.current
    attributes = { tool_name: tool_name.to_s.first(100).presence || 'unknown', error_kind: error_kind }
    attempts = 0
    begin
      issue = find_or_create_by!(attributes) do |row|
        row.first_seen_at = now
        row.last_seen_at = now
      end
      where(id: issue.id).update_all(['occurrences = occurrences + 1, last_seen_at = ?, updated_at = ?, last_message = ?, ' \
                                      'last_api_access_token_id = ?', now, now, message.to_s.gsub(/\p{Cc}/, ' ').first(250), token&.id])
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < 2
    end
  rescue StandardError => e
    Rails.logger.warn("AgentToolIssue.record! failed: #{e.class}")
    nil
  end

  def error_label = ERROR_KINDS.fetch(error_kind, error_kind)
end
