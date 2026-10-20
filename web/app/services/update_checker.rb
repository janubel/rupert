# frozen_string_literal: true

require 'json'
require 'net/http'

# Tells admins when the running build is behind the newest code on GitHub main.
# Read-only: it never installs anything. The comparison runs in a background
# job and is cached, so a page view never waits on GitHub, and any failure
# (offline, rate limit, a local build GitHub does not know) just shows nothing.
# Turn off with RUPERT_UPDATE_CHECK=off.
class UpdateChecker
  REPO = 'techmore/rupert'
  BRANCH = 'main'
  TTL = 6.hours
  RETRY_AFTER = 30.minutes

  Result = Struct.new(:current, :behind_by, :latest_message, :url, :checked_at, keyword_init: true) do
    def available? = behind_by.to_i.positive?
  end

  class << self
    def enabled?
      !Rails.env.test? && ENV.fetch('RUPERT_UPDATE_CHECK', 'on').downcase != 'off'
    end

    # Cached answer for the running build, or nil while unknown. Starts one
    # background refresh when the cache is empty.
    def pending(current: BuildInfo.current.revision)
      return unless enabled? && current != 'unversioned'

      result = Rails.cache.read(cache_key(current))
      UpdateCheckJob.perform_later if result.nil? && Rails.cache.write('update_checker/queued', true, expires_in: RETRY_AFTER, unless_exist: true)
      result if result&.available?
    end

    # Fetches the GitHub comparison and caches it. The block is the HTTP
    # fetcher (tests pass a fake); it receives a path and returns parsed JSON.
    def refresh!(current: BuildInfo.current.revision, &fetcher)
      fetcher ||= method(:get_json)
      result = build_result(current, fetcher.call("/repos/#{REPO}/compare/#{current}...#{BRANCH}"))
      Rails.cache.write(cache_key(current), result, expires_in: TTL)
      result
    rescue StandardError => e
      Rails.logger.info("UpdateChecker: #{e.class}: #{e.message}")
      nil
    end

    def build_result(current, compare)
      commits = Array(compare['commits'])
      headline = commits.last&.dig('commit', 'message').to_s.lines.first.to_s.strip
      Result.new(current: current, behind_by: compare['status'] == 'ahead' ? compare['ahead_by'].to_i : 0,
        latest_message: headline.presence, url: compare['html_url'], checked_at: Time.current)
    end

    def cache_key(current) = "update_checker/#{current}"

    private

    def get_json(path)
      http = Net::HTTP.new('api.github.com', 443)
      http.use_ssl = true
      http.open_timeout = http.read_timeout = 5
      response = http.get(path, 'Accept' => 'application/vnd.github+json', 'User-Agent' => 'rupert-update-check')
      raise "GitHub returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
