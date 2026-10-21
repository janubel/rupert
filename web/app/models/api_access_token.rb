# frozen_string_literal: true

require 'digest'

# The cleartext secret is returned by issue once, never persisted or recoverable.
class ApiAccessToken < ApplicationRecord
  include HasCuid
  include TenantScoped

  # Scope => the owner permission it also requires (checked on every request,
  # so removing the owner's permission disables the scope immediately).
  # The same scopes gate the REST API (/api/v1) and the MCP tools (/mcp).
  SCOPES = {
    'catalog:read' => 'inventory.read',
    'inventory:read' => 'inventory.read',
    'roadmap:read' => nil,
    'reports:read' => 'reports.read',
    'timesheets:read' => 'timesheets.read',
    'tasks:read' => 'projects.read',
    'alerts:read' => 'alerts.read',
    'tasks:write' => 'projects.write'
  }.freeze
  # Scopes that let an integration change Rupert's own records. None of them
  # writes to Shopify, Square or C-Trax.
  WRITE_SCOPES = %w[tasks:write].freeze
  TOKEN_FORMAT = /\Arupert_[A-Za-z0-9_-]{43}\z/

  belongs_to :user
  serialize :scopes, coder: JSON
  attribute :scopes, default: -> { [] }
  attribute :created_at, :datetime, default: -> { Time.current }
  attr_readonly :tenant_id, :user_id, :name, :token_digest, :token_hint, :scopes, :expires_at, :created_at

  validates :tenant_id, :name, :token_digest, :token_hint, presence: true
  validates :name, length: { maximum: 100 }
  validates :token_digest, uniqueness: true
  validate :valid_scopes, on: :create
  validate :owner_belongs_to_tenant, on: :create
  validate :valid_expiry, on: :create

  def self.issue(attributes:, user:, tenant:)
    secret = "rupert_#{SecureRandom.urlsafe_base64(32)}"
    token = new(attributes.slice(:name, :scopes, :expires_at).merge(
      user: user, tenant: tenant, token_digest: Digest::SHA256.hexdigest(secret),
      token_hint: "rupert_...#{secret.last(6)}"
    ))
    [token, token.save ? secret : nil]
  end

  def self.authenticate(secret)
    return unless secret.to_s.match?(TOKEN_FORMAT)

    token = unscoped.includes(:tenant, :user).find_by(token_digest: Digest::SHA256.hexdigest(secret))
    token if token&.usable?
  end

  def usable?
    !user&.employee? && revoked_at.nil? && (expires_at.nil? || expires_at > Time.current) && user&.active? &&
      tenant&.status == 'active' && (user.tenant_id == tenant_id)
  end

  def allows?(scope)
    return false unless usable? && scopes.is_a?(Array) && scopes.include?(scope)

    permission = SCOPES[scope]
    SCOPES.key?(scope) && (permission.nil? || user.can?(permission))
  end

  def display_status
    return 'Revoked' if revoked_at
    return 'Expired' if expires_at && expires_at <= Time.current

    usable? ? 'Active' : 'Owner inactive'
  end

  private

  def valid_scopes
    unless scopes.is_a?(Array) && scopes.any? && scopes.uniq == scopes && (scopes - SCOPES.keys).empty?
      errors.add(:scopes, 'must contain one or more supported, distinct scopes')
      return
    end
    scopes.each do |scope|
      permission = SCOPES[scope]
      errors.add(:scopes, "requires #{permission} permission") if permission && !user&.can?(permission)
    end
  end

  def owner_belongs_to_tenant
    return if user && (user.tenant_id == tenant_id)

    errors.add(:user, 'must belong to this store')
  end

  def valid_expiry
    if expires_at_before_type_cast.present? && expires_at.nil?
      errors.add(:expires_at, 'must be a valid date and time')
    elsif expires_at && expires_at <= Time.current
      errors.add(:expires_at, 'must be in the future')
    end
  end
end
