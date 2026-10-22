# frozen_string_literal: true

module Mcp
  # Finds the person a task is for from what someone typed: "me", "nobody",
  # an email, or a name. Only active people in the same workspace.
  module Assignee
    NOBODY = %w[nobody none unassigned no-one noone].freeze
    ME = %w[me myself].freeze

    PROPERTY = {
      type: 'string', maxLength: 120,
      description: 'Who it is for: a person\'s name or email, "me" (the person asking) or "nobody" to unassign.'
    }.freeze

    module_function

    # Returns a User, or :nobody. Raises ToolError when nobody or more than one person matches.
    def resolve(owner, text)
      value = text.to_s.strip.delete_prefix('@')
      down = value.downcase
      return :nobody if NOBODY.include?(down)
      return owner if ME.include?(down)

      people = User.where(tenant_id: owner.tenant_id).active.to_a
      matches = people.select { |person| person.email.to_s.downcase == down }
      matches = people.select { |person| person.display_name.downcase == down } if matches.empty?
      if matches.empty?
        matches = people.select do |person|
          name = person.display_name.downcase
          name.split(/\s+/).include?(down) || name.start_with?(down) || person.email.to_s.downcase.split('@').first == down
        end
      end
      return matches.first if matches.one?
      raise ToolError.new("No active person in this workspace matches “#{value.first(60)}”. Ask for their name or email.", kind: 'not_found') if matches.empty?

      choices = matches.first(6).map { |person| "#{person.display_name} (#{person.email.to_s.split('@').first}@…)" }
      raise ToolError.new("“#{value.first(60)}” matches #{matches.size} people: #{choices.join(', ')}. Ask which one and pass their email.",
        kind: 'invalid_arguments')
    end

    # "Jan Ubel", or "Shawn Dolbec (sdolbec1@…)" when another active person has the same name.
    def label(person)
      return 'nobody' if person == :nobody

      twins = User.where(tenant_id: person.tenant_id, name: person.name).active.where.not(id: person.id).exists? if person.name.present?
      twins ? "#{person.display_name} (#{person.email.to_s.split('@').first}@…)" : person.display_name
    end
  end
end
