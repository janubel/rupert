# frozen_string_literal: true

require 'test_helper'
require 'erb'
require 'yaml'
require 'timeout'

module ChatWorkerIsolationProbes
  STARTED = Queue.new
  RELEASE = Queue.new
  FINISHED = Queue.new

  class Chat < TeamChat::ReplyJob
    self.queue_adapter = :solid_queue

    def perform
      STARTED << :chat
      RELEASE.pop
    end
  end

  class Sync < SyncJob
    self.queue_adapter = :solid_queue
    def perform = FINISHED << :sync
  end

  class Monitor < AiHealthCheckJob
    self.queue_adapter = :solid_queue
    def perform = FINISHED << :monitor
  end

  class Backup < BackupJob
    self.queue_adapter = :solid_queue
    def perform = FINISHED << :backup
  end
end

class ChatWorkerIsolationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def worker_config(environment)
    YAML.safe_load(ERB.new(Rails.root.join('config/queue.yml').read).result, aliases: true).fetch(environment).fetch('workers')
  end

  test 'both inference jobs have a dedicated queue and all operational jobs remain covered' do
    Rails.application.eager_load!
    %w[development test production].each do |environment|
      workers = worker_config(environment)
      assert_equal 2, workers.size
      assert_equal ['default', 'chat'], workers.pluck('queues')
      assert_equal [1, 1], workers.last.values_at('threads', 'processes')
    end
    assert_equal 'chat', TeamChat::ReplyJob.queue_name
    assert_equal 'chat', AskRupertReplyJob.queue_name
    ApplicationJob.descendants.select { |job| job.instance_method(:perform).source_location&.first&.start_with?(Rails.root.join('app/jobs').to_s) }.each do |job|
      assert_includes %w[default chat], job.queue_name, "#{job.name} has no configured worker"
    end
  end

  test 'a saturated chat worker cannot claim operational work or block sync monitor and backup workers' do
    probes = ChatWorkerIsolationProbes
    workers = worker_config('production').map do |config|
      SolidQueue::Worker.new(**config.symbolize_keys.merge(polling_interval: 0.02))
    end
    probes::Chat.perform_later
    workers.each(&:start)
    assert_equal :chat, Timeout.timeout(10) { probes::STARTED.pop }
    probes::Chat.perform_later # keep the inference queue saturated
    probes::Sync.perform_later
    probes::Monitor.perform_later
    probes::Backup.perform_later

    finished = Timeout.timeout(10) { 3.times.map { probes::FINISHED.pop } }
    assert_equal %i[backup monitor sync], finished.sort
    assert_equal 1, SolidQueue::ClaimedExecution.joins(:job).where(solid_queue_jobs: { class_name: probes::Chat.name }).count
    assert_equal 1, SolidQueue::ReadyExecution.joins(:job).where(solid_queue_jobs: { class_name: probes::Chat.name }).count
  ensure
    2.times { probes::RELEASE << true } if probes
    workers&.each(&:stop)
    if probes
      SolidQueue::Job.where(class_name: [probes::Chat.name, probes::Sync.name, probes::Monitor.name, probes::Backup.name]).destroy_all
      [probes::STARTED, probes::RELEASE, probes::FINISHED].each { |queue| queue.pop until queue.empty? }
    end
    Current.reset
  end
end
