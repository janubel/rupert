# frozen_string_literal: true

# Diagnostics captured with an in-app report: a page screenshot, a sanitized
# page snapshot, browser details, recent JavaScript errors, and the server log
# lines and SQL queries of the reporter's last few requests. Only store admins
# and the platform owner may read them; the reporter and other staff see just
# the report's status. Everything here is untrusted text: capped on write,
# shown escaped, never executed.
class FeedbackAttachment < ApplicationRecord
  include TenantScoped

  KINDS = {
    'screenshot' => 'Screenshot', 'dom_snapshot' => 'Page snapshot', 'client_context' => 'Browser details',
    'js_errors' => 'Recent JavaScript errors', 'server_log' => 'Server log lines', 'sql_queries' => 'SQL queries'
  }.freeze
  TEXT_LIMITS = {
    'dom_snapshot' => 200_000, 'client_context' => 8_000, 'js_errors' => 20_000, 'server_log' => 60_000, 'sql_queries' => 60_000
  }.freeze
  SCREENSHOT_LIMIT = 1_500_000
  IMAGE_TYPES = { 'image/png' => "\x89PNG".b, 'image/jpeg' => "\xFF\xD8\xFF".b }.freeze
  ADMIN_ROLES = %w[admin super_admin].freeze

  belongs_to :agent_feedback

  validates :tenant_id, presence: true
  validates :kind, inclusion: { in: KINDS.keys }, uniqueness: { scope: :agent_feedback_id }
  validate :within_limit

  # Attachments can hold page contents, so they are an administrator view.
  def self.viewable_by?(user)
    user.present? && user.active? && ADMIN_ROLES.include?(user.role)
  end

  # Text attachments are cut at the kind's limit on a character boundary.
  def self.clip(kind, text)
    text.to_s.scrub('').gsub(/[^\P{Cc}\n\t]/, '').byteslice(0, TEXT_LIMITS.fetch(kind)).to_s.scrub('')
  end

  # PNG or JPEG only, judged by the bytes and not the declared type.
  def self.image_type(bytes)
    IMAGE_TYPES.find { |_type, magic| bytes.to_s.b.start_with?(magic) }&.first
  end

  def screenshot? = kind == 'screenshot'
  def label = KINDS.fetch(kind, kind)

  private

  def within_limit
    size = screenshot? ? binary_body.to_s.bytesize : text_body.to_s.bytesize
    self.byte_size = size
    limit = screenshot? ? SCREENSHOT_LIMIT : TEXT_LIMITS.fetch(kind, 0)
    errors.add(:base, "#{label} is too large") if size > limit
    errors.add(:base, 'Screenshot must be a PNG or JPEG image') if screenshot? && self.class.image_type(binary_body).nil?
  end
end
