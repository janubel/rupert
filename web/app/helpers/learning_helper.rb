# frozen_string_literal: true

module LearningHelper
  def learning_journey
    @learning_journey ||= LearningJourney.new(Current.user)
  end

  def getting_started_checklist
    @getting_started_checklist ||= GettingStartedChecklist.new(Current.user, journey: learning_journey)
  end

  # The guided tour for the current page, if one exists for this person.
  def learning_tour
    return @learning_tour if defined?(@learning_tour)

    @learning_tour = Current.user && PageTours.for_path(request.path, Current.user)
  end

  # Marks an element as a tour stop: <section <%= tour_anchor('stats') %>>.
  def tour_anchor(key)
    tag.attributes('data-tour': key.to_s)
  end

  # Inline plain-language definition beside a label. Renders a native
  # disclosure so it works without JavaScript; the stylesheet floats the open
  # panel like a popover and the navigation-menu controller closes it on
  # Escape or an outside click. Place it inside a <div>, <th>, <dt> or <span>
  # wrapper, never inside a <p>: browsers close a paragraph when a <details>
  # starts, which pushes the mark onto its own line.
  #
  #   <%= define('mirror') %>                                → a small "?" mark after the label
  #   <%= define('sales_total', label: 'Recorded sales') %>  → the label itself becomes the trigger
  def define(term, label: nil, inline: true, css_class: nil)
    term = term.to_s
    entry = LearningCatalog::TERMS[term]
    return ''.html_safe unless entry

    name, definition = entry
    tag.details(class: ['term', ('term-inline' if inline), css_class].compact.join(' '),
      data: { controller: 'navigation-menu term', term: term }) do
      safe_join([
        tag.summary(class: label ? 'term-label' : 'term-trigger', title: "What does #{name.downcase} mean?") do
          safe_join([
            (label ? label.to_s : tag.span("What does #{name.downcase} mean?", class: 'sr-only')),
            tag.span('?', class: 'term-mark', aria: { hidden: true })
          ], ' ')
        end,
        tag.div(class: 'term-panel', role: 'note') do
          safe_join([
            tag.p(name, class: 'term-name'),
            tag.p(definition, class: 'term-definition'),
            link_to('All definitions', learning_index_path(anchor: "term-#{term}"), class: 'term-more')
          ])
        end
      ])
    end
  end

  # Quick inline list of definitions, used where several unfamiliar words sit together.
  def definitions_for(*terms)
    render 'shared/definitions', terms: terms.flatten.map(&:to_s)
  end

  # "How is this calculated?" beside a live figure. Rows are [label, value]
  # pairs built from the page's own data; formula is a one-line explanation.
  def explain_calculation(title:, rows:, formula: nil, note: nil, lesson: nil, term: nil, id: nil, summary: 'How is this calculated?')
    render 'shared/calculation', title: title, rows: rows, formula: formula, note: note, lesson: lesson, term: term, id: id,
      summary: summary
  end

  # Quiz questions in a lesson, normalised to an array of hashes.
  def lesson_questions(lesson)
    LearningCatalog.questions(lesson)
  end

  def learning_minutes(minutes)
    "#{minutes} min"
  end
end
