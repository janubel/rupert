# frozen_string_literal: true

require 'securerandom'

module TeamChat
  # A fixed set of questions (config/team_chat/battery.yml) asked to one bot in
  # the bot's own test room (#test-liquid, #test-qwen, ...), one at a time, timed. Each answer is then graded by
  # DeepSeek (Battery::Grader) against the data Rupert's own tools return for the
  # same question, and the grade is posted under it. Everyone in the room can
  # watch a run; the summary is posted and pinned at the end.
  #
  # Questions only read data. A bot that proposes a change anyway gets its card
  # dismissed, so a test run never changes anything.
  class Battery
    # Each bot has its own test room (#test-liquid, #test-qwen, ...). Runs from before that are in #liquid-testing.
    LEGACY_ROOM_SLUG = 'liquid-testing'
    ROOM_TOPIC = 'Test runs for @%<handle>s: a fixed set of questions, each answer timed and graded 1–5 by DeepSeek against Rupert’s own data. Scorecard: Model scores → Test runs.'
    CONFIG = Rails.root.join('config/team_chat/battery.yml')

    Item = Struct.new(:id, :cadence, :question, :checks, :expect, keyword_init: true)
    Result = Struct.new(:item, :seconds, :tools, :status, :answer, :grade, :tokens_in, :tokens_out, :unverified, :message_id, keyword_init: true)

    attr_reader :run_id, :room, :results, :record

    # The question set: the default battery, or config/team_chat/battery_<name>.yml (e.g. finance).
    def self.config_for(name)
      name = name.to_s.strip
      return CONFIG if name.blank? || name == 'default'
      raise ArgumentError, "Battery names are lowercase letters, digits and _: #{name.first(40)}" unless name.match?(/\A[a-z0-9_]+\z/)

      path = Rails.root.join("config/team_chat/battery_#{name}.yml")
      raise ArgumentError, "No battery called #{name} (#{path.basename} is missing)." unless path.exist?

      path
    end

    def self.items(path = CONFIG)
      YAML.safe_load_file(path).fetch('questions').map do |row|
        Item.new(id: row.fetch('id'), cadence: row.fetch('cadence'), question: row.fetch('question'), checks: Array(row['checks']),
          expect: row['expect'].to_s.squish.presence)
      end
    end

    # user: who the questions are asked as (their permissions). agent: a local bot handle, or 'rupert'.
    attr_reader :set

    def initialize(user:, agent: 'liquid', only: nil, grader: Grader.new, items: self.class.items, out: $stdout, set: 'default')
      @set = set.to_s.presence || 'default'
      @user = user
      @agent = agent.to_s == 'rupert' ? nil : (LocalAgents.find(agent) || LocalAgents.trial(agent))
      raise ArgumentError, "No bot @#{agent} is available here." if agent.to_s != 'rupert' && !@agent

      wanted = Array(only).map(&:to_s).compact_blank
      @items = wanted.any? ? items.select { |item| wanted.include?(item.id) } : items
      @partial = wanted.any?
      @grader = grader
      @out = out
      @run_id = "#{Time.current.strftime('%Y%m%d-%H%M')}-#{SecureRandom.hex(2)}"
      @results = []
    end

    def handle = @agent&.handle || 'rupert'
    def bot_name = @agent&.name || 'Rupert'

    def self.room_slug(handle) = "test-#{handle.presence || 'rupert'}"

    # The bot's test room, created (with every chat user in it) the first time.
    def self.room_for(user, handle = 'liquid')
      slug = room_slug(handle)
      room = Room.find_by(slug: slug) ||
             Room.create!(name: slug, slug: slug, kind: 'channel', topic: format(ROOM_TOPIC, handle: handle.presence || 'rupert'),
               assistant_mode: 'off', created_by: user)
      Post.mentionable.each { |person| room.membership_for(person) }
      room
    end

    # A test room for @rupert, every @bot and every trial model, so people can open them before any run.
    def self.ensure_rooms!(user)
      (['rupert'] + LocalAgents.all.map(&:handle) + (LocalAgents.enabled? ? LocalAgents::TRIALS.map(&:handle) : [])).map { |handle| room_for(user, handle) }
    end

    def run
      @room = self.class.room_for(@user, handle)
      started = Time.current
      post_notice("🧪 Test run #{@run_id}#{" (#{@set} questions)" unless @set == 'default'}: #{@items.size} questions to @#{handle} (#{model_name}), asked as #{@user.display_name}. " \
                  "Each answer is timed and graded 1–5 by #{@grader.label} against Rupert’s own data.")
      @record = BatteryRun.create!(run_key: @run_id, set_name: record_set_name, agent: @agent&.handle, model: model_name,
        engine: (@agent ? 'local_gateway' : ModelConfig.current.engine), revision: self.class.revision, status: 'running',
        questions: @items.size, results: [], room: @room, started_at: started)
      @items.each_with_index do |item, index|
        @results << run_item(item, index)
        @record.update!(results: @record.results_list + [result_row(@results.last)])
        @record.tally!
      end
      @record.update!(status: 'done', finished_at: Time.current)
      summary = post_notice(summary_text(Time.current - started))
      summary.toggle_pin!(@user) unless summary.pinned?
      @results
    end

    def self.revision = BuildInfo.current.short_revision

    # The saved name of this run's question set; a run of only some questions is marked so it never counts as the full set.
    def record_set_name = @partial ? "#{@set} (part)" : @set

    # The same bot, model and question set already finished on this Rupert build, if any.
    def already_done = BatteryRun.already_done(agent: @agent&.handle, model: model_name, set_name: record_set_name, revision: self.class.revision)

    def model_name = (@agent ? ModelConfig.for_local(@agent) : ModelConfig.current).model

    # Markdown for docs: one row per question.
    def report_markdown
      lines = ["### Run #{@run_id}#{" (#{@set})" unless @set == 'default'}: @#{handle} (#{model_name}), graded by #{@grader.label}", '',
               '| # | Cadence | Question | Time | Tools | Grade | Grader’s note |', '| --- | --- | --- | --- | --- | --- | --- |']
      @results.each_with_index do |result, index|
        lines << "| #{index + 1} | #{result.item.cadence} | #{result.item.question.tr('|', '/')} | #{format_seconds(result.seconds)} | " \
                 "#{result.tools.join(', ').presence || '—'} | #{result.grade&.dig(:score) || '—'} | #{result.grade&.dig(:verdict).to_s.tr('|', '/').tr("\n", ' ')} |"
      end
      lines << '' << summary_text(nil)
      lines.join("\n")
    end

    private

    def run_item(item, index)
      log "[#{index + 1}/#{@items.size}] #{item.cadence}: #{item.question}"
      question = @room.messages.create!(user: @user, body: "@#{handle} #{item.question}",
        meta: { 'battery' => @run_id, 'item' => item.id, 'cadence' => item.cadence })
      reply = @room.messages.create!(author_kind: 'assistant', status: 'pending', activity: @agent ? "Loading #{@agent.name}" : 'Thinking',
        meta: { 'asked_by' => @user.id, 'trigger_id' => question.id, 'agent' => @agent&.handle, 'battery' => @run_id, 'isolated' => true }.compact)
      Agent.new(reply).run
      reply.reload
      dismiss_proposals(reply)
      meta = reply.meta.to_h
      seconds = meta['duration_ms'].to_f / 1000
      grade = grade_for(item, reply)
      post_grade(reply, grade, seconds) if grade
      log "    #{reply.status} in #{format_seconds(seconds)} · tools #{Array(meta['tools']).join(', ').presence || 'none'} · grade #{grade&.dig(:score) || '—'}"
      Result.new(item: item, seconds: seconds, tools: Array(meta['tools']), status: reply.status, answer: reply.body.to_s,
        grade: grade, tokens_in: meta['tokens_in'], tokens_out: meta['tokens_out'], unverified: Array(meta['unverified']), message_id: reply.id)
    end

    def result_row(result)
      { 'id' => result.item.id, 'cadence' => result.item.cadence, 'question' => result.item.question, 'status' => result.status,
        'seconds' => result.seconds.round(1), 'tools' => result.tools, 'grade' => result.grade&.dig(:score),
        'verdict' => result.grade&.dig(:verdict).to_s.first(300), 'unverified' => result.unverified.to_a, 'message_id' => result.message_id }
    end

    def grade_for(item, reply)
      return { score: 1, verdict: "No answer: the reply #{reply.status == 'failed' ? 'failed' : 'was empty'}.", issues: [] } if reply.status != 'done' || reply.body.blank?

      @grader.grade(question: item.question, answer: reply.body.to_s, reference: reference_for(item), tools_used: Array(reply.meta.to_h['tools']),
        expect: item.expect)
    rescue Grader::Error => e
      log "    grading failed: #{e.message.first(160)}"
      nil
    end

    # What Rupert's own tools say for this question, so the grader has the truth to compare with.
    def reference_for(item)
      token = Token.new(@user)
      item.checks.map do |check|
        name = check.is_a?(Hash) ? check['tool'] : check.to_s
        args = (check.is_a?(Hash) ? check['args'].to_h : {}).transform_values { |value| preset_date(value) }
        tool = Mcp::Registry.find(name)
        next "#{name}: not available" unless tool&.available_to?(token)

        outcome = tool.new(token: token).call(args)
        "#{name}(#{JSON.generate(args)}):\n#{AskRupert::Redactor.personal("#{outcome.text}\n#{JSON.generate(outcome.data)}").first(Grader::REFERENCE_CHARS)}"
      rescue Mcp::ToolError => e
        "#{name}: error #{e.message.first(200)}"
      end.join("\n\n")
    end

    # "last_month.from" → that preset's first day, so the battery file can name moving dates.
    def preset_date(value)
      key, edge = value.to_s.match(/\A(\w+)\.(from|to)\z/)&.captures
      preset = TimeRangePicker.preset(key, Date.current) if key
      preset ? preset.public_send(edge).iso8601 : value
    end

    def post_grade(reply, grade, seconds)
      issues = Array(grade[:issues]).first(3).map { |issue| "\n- #{issue}" }.join
      flagged = Array(reply.meta.to_h['unverified'])
      issues += "\n⚠ Number check: #{flagged.join(', ')} not found in Rupert's data." if flagged.any?
      @room.messages.create!(author_kind: 'system', parent_id: nil,
        body: "Grade #{grade[:score]}/5 for #{bot_name} (#{format_seconds(seconds)}, #{Array(reply.meta.to_h['tools']).join(', ').presence || 'no tools'}): " \
              "#{grade[:verdict]}#{issues}\n— graded by #{@grader.label} in #{format_seconds(grade[:seconds].to_f)}",
        meta: { 'battery' => @run_id, 'grade' => grade[:score], 'graded_message' => reply.id })
    end

    def dismiss_proposals(reply)
      reply.actions_list.select { |action| action['status'] == 'proposed' }.each do |action|
        Actions.decide!(reply, action['id'], user: @user, approve: false)
      end
    end

    def summary_text(elapsed)
      graded = @results.filter_map { |result| result.grade&.dig(:score) }
      times = @results.map(&:seconds).select(&:positive?)
      by_cadence = @results.group_by { |result| result.item.cadence }.map do |cadence, rows|
        scores = rows.filter_map { |row| row.grade&.dig(:score) }
        "#{cadence} #{scores.any? ? format('%.1f', scores.sum.to_f / scores.size) : '—'}"
      end
      [
        "📋 Test run #{@run_id} done: @#{handle} (#{model_name}) answered #{@results.count { |result| result.status == 'done' }}/#{@results.size}.",
        ("Average grade #{format('%.1f', graded.sum.to_f / graded.size)}/5 (#{graded.tally.sort.reverse.map { |score, count| "#{count}× #{score}" }.join(', ')})." if graded.any?),
        ("Time per answer: average #{format_seconds(times.sum / times.size)}, fastest #{format_seconds(times.min)}, slowest #{format_seconds(times.max)}." if times.any?),
        ("By cadence: #{by_cadence.join(' · ')}." if by_cadence.any?),
        "Number check: figures not found in Rupert's data in #{@results.count { |result| result.unverified.to_a.any? }} of #{@results.size} answers.",
        ("Whole run took #{format_seconds(elapsed)}." if elapsed)
      ].compact.join("\n")
    end

    def post_notice(text) = @room.messages.create!(author_kind: 'system', body: text.first(Message::BODY_MAX), meta: { 'battery' => @run_id })

    def format_seconds(seconds)
      seconds = seconds.to_f
      seconds >= 90 ? "#{(seconds / 60).floor} min #{(seconds % 60).round} s" : "#{seconds.round(1)} s"
    end

    def log(text) = @out&.puts(text)
  end
end
