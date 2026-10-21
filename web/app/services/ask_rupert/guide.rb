# frozen_string_literal: true

module AskRupert
  # "Where is it?" and "how do I?" answers built from the real navigation and
  # the real lesson catalog, for one person. A page or lesson appears only if
  # the server would let that person open it (ModuleRegistry.nav_for and
  # LearningCatalog.available), so the assistant cannot point anyone at a page
  # they cannot use. Pages that exist but are not theirs are named, without a
  # link, so the answer can say "ask an administrator".
  class Guide
    STOP_WORDS = %w[a an and are as at be can do does for from get go how i in is it its me my of on open or see show
                    the this to we what where whats which with you your please find look want need
                    way take let make show tell].freeze

    # Words people use that the page name does not contain. Kept short and plain.
    SYNONYMS = {
      'dashboard' => 'home overview summary today', 'sales' => 'orders revenue sold sale sell transactions receipts',
      'ctrax_pos' => 'register till checkout pos cashier ring', 'registers' => 'till drawer cash shift',
      'customers' => 'crm contacts clients shoppers buyers', 'inventory' => 'stock products items sku quantity catalog',
      'inventory_counts' => 'count counting recount stocktake cycle', 'alerts' => 'low reorder shortage notification',
      'locations' => 'store warehouse', 'stock_requests' => 'transfer backorder move',
      'reports' => 'report analytics numbers export', 'sales_tax' => 'tax taxes',
      'timesheets' => 'hours time punch clock approve', 'time_clock' => 'clock punch shift hours in out',
      'time_keeping' => 'scheduled worked hours', 'leave' => 'pto vacation holiday sick off',
      'payroll' => 'pay wages salary payslip', 'employees' => 'staff people workers hr',
      'accounts' => 'users logins people invite', 'permissions' => 'roles access rights who can',
      'settings' => 'configure preferences setup', 'connections' => 'credentials api keys shopify square integrate',
      'sync' => 'refresh pull import update fresh stale', 'system' => 'server health version',
      'bookkeeping' => 'books accounting finance money', 'financial_close' => 'close end day',
      'bank_statements' => 'bank upload csv', 'ledger' => 'journal entries',
      'tasks' => 'todo assignments work to-do', 'projects' => 'project plan', 'roadmap' => 'features upcoming new',
      'api_access_tokens' => 'token mcp api', 'agent_feedback' => 'feedback bugs reports ai',
      'receipts' => 'receipt expense reimburse', 'marketing' => 'campaign email discount', 'warehouse' => 'wholesale b2b',
      'cash_forecast' => 'cashflow forecast', 'vendors' => 'suppliers', 'purchase_orders' => 'po buy order supplier'
    }.freeze

    # Things people look for that are menus or tools, not pages.
    EXTRAS = [
      { title: 'Appearance (light, dark and other looks)', where: 'Account menu (your initials, top right) → Appearance',
        words: 'appearance theme dark light mode color colour look display sepia mist' },
      { title: 'Sign out', where: 'Account menu (your initials, top right) → Sign out', words: 'sign out log out logout leave' },
      { title: 'Search', where: 'The magnifying glass in the header, or press /', words: 'search find lookup' },
      { title: 'Help panel', where: 'The ? button in the header, or press ?', words: 'help tour guide shortcuts keyboard' }
    ].freeze

    Page = Struct.new(:key, :title, :area, :path, :words, keyword_init: true)

    def initialize(user)
      @user = user
    end

    # Pages this person can open that match, best first.
    def where_is(query, limit: 4)
      tokens = tokenize(query)
      pages = rank(permitted_pages, tokens, limit)
      extras = rank_extras(tokens)
      { pages: pages.map { |page, score| page_payload(page, score) },
        elsewhere: extras,
        not_available: not_available(tokens, pages.map { |page, _| page.key }) }
    end

    # Lessons and definitions that match, with their steps.
    def how_do_i(query, limit: 2)
      tokens = tokenize(query)
      lessons = rank_lessons(tokens, limit)
      { lessons: lessons, terms: rank_terms(tokens, 2) }
    end

    def permitted_pages
      @permitted_pages ||= begin
        areas = ModuleRegistry.areas_for(@user).to_h { |area| [area[:key], area[:name]] }
        ModuleRegistry.nav_for(@user).filter_map do |entry|
          path = path_for(entry)
          next if path.blank? || path == '#'

          words = [entry.key.tr('_', ' '), SYNONYMS[entry.key]].compact.join(' ')
          Page.new(key: entry.key, title: entry.name, area: areas[ModuleRegistry.area_key_for(entry.key)], path: path, words: words)
        end
      end
    end

    def lesson_for(path)
      LearningCatalog.for_path(path, @user)
    end

    # The lesson (if any) for a page, as a link.
    def lesson_link(path)
      lesson = lesson_for(path)
      lesson && { title: lesson[:title], path: urls.learning_path(lesson[:key]) }
    end

    def tokenize(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).reject { |word| STOP_WORDS.include?(word) }.map { |word| stem(word) }.uniq.first(12)
    end

    private

    def urls = Rails.application.routes.url_helpers

    def path_for(entry)
      urls.instance_exec(&entry.path)
    rescue StandardError
      nil
    end

    def stem(word)
      return word if word.length <= 3

      word.sub(/(ies)\z/, 'y').sub(/(ing|es|s)\z/, '')
    end

    def score(haystack_words, title_words, tokens)
      tokens.sum do |token|
        if title_words.include?(token) then 4
        elsif haystack_words.include?(token) then 3
        elsif token.length >= 4 && (title_words + haystack_words).any? { |word| word.start_with?(token) } then 2
        else 0
        end
      end
    end

    def rank(pages, tokens, limit)
      return [] if tokens.empty?

      pages.filter_map do |page|
        title_words = tokenize_all(page.title)
        total = score(tokenize_all(page.words), title_words, tokens)
        total += 1 if tokenize_all(page.area).intersect?(tokens)
        [page, total] if total.positive?
      end.sort_by { |page, total| [-total, page.title] }.first(limit)
    end

    def tokenize_all(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).map { |word| stem(word) }
    end

    def rank_extras(tokens)
      EXTRAS.filter_map do |extra|
        extra.slice(:title, :where) if score(tokenize_all(extra[:words]), tokenize_all(extra[:title]), tokens) >= 3
      end.first(2)
    end

    def page_payload(page, _score)
      { title: page.title, area: page.area, path: page.path, lesson: lesson_link(page.path) }.compact
    end

    # Registered pages the person cannot open, named only when the match is strong.
    def not_available(tokens, shown_keys)
      return [] if tokens.empty?

      visible = permitted_pages.map(&:key) + shown_keys
      ModuleRegistry.all.filter_map do |entry|
        next if visible.include?(entry.key) || %w[platform system].include?(entry.key)

        hits = score(tokenize_all([entry.key.tr('_', ' '), SYNONYMS[entry.key]].compact.join(' ')), tokenize_all(entry.name), tokens)
        entry.name if hits >= 4
      end.uniq.first(2)
    end

    def rank_lessons(tokens, limit)
      return [] if tokens.empty?

      LearningCatalog.available(@user).filter_map do |lesson|
        vocabulary = lesson[:terms].flat_map { |term| LearningCatalog::TERMS.fetch(term) { [] } }
        title_words = tokenize_all(lesson[:title])
        body = tokenize_all([lesson[:summary], *lesson[:steps], *vocabulary, lesson[:key]].join(' '))
        total = score(body, title_words, tokens)
        [lesson, total] if total >= 3
      end.sort_by { |lesson, total| [-total, lesson[:title]] }.first(limit).map { |lesson, _| lesson_payload(lesson) }
    end

    def lesson_payload(lesson)
      { title: lesson[:title], minutes: lesson[:minutes], summary: lesson[:summary], steps: lesson[:steps].map { |step| step.to_s.first(420) },
        path: urls.learning_path(lesson[:key]), opens: lesson[:destination], action: lesson[:action] }
    end

    def rank_terms(tokens, limit)
      return [] if tokens.empty?

      LearningCatalog::TERMS.filter_map do |key, (label, definition)|
        total = score(tokenize_all(definition), tokenize_all("#{label} #{key.tr('_', ' ')}"), tokens)
        [{ term: label, definition: definition.to_s.first(300) }, total] if total >= 4
      end.sort_by { |_, total| -total }.first(limit).map(&:first)
    end
  end
end
